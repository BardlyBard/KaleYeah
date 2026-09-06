import Foundation

/// Reusable IMAP/SMTP connector for Gmail and Microsoft 365 (GoDaddy Email Essentials).
enum IMAPAccountSyncService {
    static func storedEmail(provider: MailIMAPProvider) -> String? {
        UserDefaults.standard.string(forKey: provider.userDefaultsEmailKey)
    }

    static func storedAccountID(provider: MailIMAPProvider) -> UUID? {
        if let s = UserDefaults.standard.string(forKey: provider.userDefaultsAccountIDKey) {
            return UUID(uuidString: s)
        }
        return nil
    }

    static func rememberAccount(provider: MailIMAPProvider, email: String, id: UUID) {
        UserDefaults.standard.set(email, forKey: provider.userDefaultsEmailKey)
        UserDefaults.standard.set(id.uuidString, forKey: provider.userDefaultsAccountIDKey)
    }

    static func clearRememberedAccount(provider: MailIMAPProvider) {
        UserDefaults.standard.removeObject(forKey: provider.userDefaultsEmailKey)
        UserDefaults.standard.removeObject(forKey: provider.userDefaultsAccountIDKey)
    }

    static func hasKeychainCredentials(provider: MailIMAPProvider, email: String? = nil) -> Bool {
        let address = email ?? storedEmail(provider: provider) ?? provider.defaultEmail
        return KeychainCredentialStore.hasCredentials(forEmail: address)
    }

    static func testConnection(provider: MailIMAPProvider, email: String, password: String) async throws {
        let imap = SimpleIMAPClient()
        try await imap.connect(host: provider.imapHost, port: provider.imapPort)
        try await imap.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        _ = try await imap.listFolders()
        await imap.logout()

        let smtp = SimpleSMTPClient()
        try await connectSMTP(smtp, provider: provider)
        try await smtp.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        await smtp.quit()
    }

    /// LIST only — used so the ladder can show Gmail labels before message hydrate finishes.
    static func listFolders(provider: MailIMAPProvider, email: String, password: String) async throws -> [IMAPFolderInfo] {
        let imap = SimpleIMAPClient()
        try await imap.connect(host: provider.imapHost, port: provider.imapPort)
        try await imap.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        let listed = try await imap.listFolders()
        await imap.logout()
        return listed
    }

    static func sync(
        provider: MailIMAPProvider,
        email: String,
        password: String,
        accountID: UUID,
        folderIDs: IMAPFolderIDs,
        extraFolders: [(mailbox: String, folderID: UUID)] = []
    ) async throws -> (messages: [MailMessage], remoteFolders: [IMAPFolderInfo], result: IMAPSyncResult) {
        let imap = SimpleIMAPClient()
        try await imap.connect(host: provider.imapHost, port: provider.imapPort)
        try await imap.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        let listed = try await imap.listFolders()

        var picked: [(IMAPFolderInfo, UUID)] = []
        var seenMailboxes = Set<String>()

        func take(_ info: IMAPFolderInfo, folderID: UUID) {
            guard info.isSelectable, seenMailboxes.insert(info.name).inserted else { return }
            picked.append((info, folderID))
        }

        if let inbox = listed.first(where: { $0.kind == .inbox }) ?? listed.first(where: { $0.name.uppercased() == "INBOX" }) {
            take(inbox, folderID: folderIDs.inbox)
        }
        if let sent = listed.first(where: { $0.kind == .sent }) {
            take(sent, folderID: folderIDs.sent)
        }
        if let drafts = listed.first(where: { $0.kind == .drafts }) {
            take(drafts, folderID: folderIDs.drafts)
        }
        if let trash = listed.first(where: { $0.kind == .trash }) {
            take(trash, folderID: folderIDs.trash)
        }
        if let archive = listed.first(where: { $0.kind == .archive }) {
            take(archive, folderID: folderIDs.archive)
        }

        // Caller-provided extras (Starred / Important / user labels) — already upserted into the ladder.
        let extraByMailbox = Dictionary(uniqueKeysWithValues: extraFolders.map { ($0.mailbox, $0.folderID) })
        var extraHydrated = 0
        let extraCap = 16
        // Prefer Starred/Important first when capping.
        let extrasOrdered = listed.filter { info in
            info.isSelectable && !info.isGmailAllMail && extraByMailbox[info.name] != nil
        }.sorted { a, b in
            let rank: (IMAPFolderInfo) -> Int = { info in
                switch info.ladderName.uppercased() {
                case "STARRED": return 0
                case "IMPORTANT": return 1
                default: return 2
                }
            }
            return rank(a) < rank(b)
        }
        for info in extrasOrdered {
            guard extraHydrated < extraCap, let id = extraByMailbox[info.name] else { continue }
            take(info, folderID: id)
            extraHydrated += 1
        }

        // Also auto-pick any useful labels LIST returned that are not yet on the ladder /
        // not in extras (first run, or newly created Gmail labels).
        let auto = Self.defaultMessageSyncTargets(listed: listed, accountID: accountID, excluding: seenMailboxes)
        for (info, folderID) in auto {
            guard picked.count < 6 + extraCap else { break } // well-known (~5) + customs
            take(info, folderID: folderID)
        }

        var all: [MailMessage] = []
        var incrementalFolders = 0
        var hydrateFolders = 0
        var folderErrors: [String] = []
        for (info, folderID) in picked {
            do {
                let cursor = MailMessageCache.imapCursor(provider: provider.rawValue, email: email, mailbox: info.name)
                let state = try await imap.selectState(info.name)
                let fetched: [IMAPFetchedMessage]
                let usedIncremental: Bool
                if let cursor,
                   cursor.uidValidity != 0,
                   state.uidValidity != 0,
                   cursor.uidValidity == state.uidValidity {
                    // UID high-water: only pull UIDs newer than the last successful sync.
                    fetched = try await imap.fetchUIDs(afterUID: cursor.highestUID, includeBodies: true)
                    usedIncremental = true
                    incrementalFolders += 1
                } else {
                    if cursor != nil, state.uidValidity != 0, cursor?.uidValidity != state.uidValidity {
                        MailMessageCache.clearIMAPCursor(provider: provider.rawValue, email: email, mailbox: info.name)
                    }
                    fetched = try await imap.fetchRecent(limit: provider.recentLimit)
                    usedIncremental = false
                    hydrateFolders += 1
                }

                var maxUID: UInt32 = cursor?.highestUID ?? 0
                if usedIncremental == false {
                    maxUID = 0
                }
                for item in fetched {
                    maxUID = max(maxUID, item.uid)
                    let id = stableMessageID(provider: provider, email: email, mailbox: info.name, uid: item.uid)
                    var attachments: [MailAttachment] = []
                    for raw in item.rawAttachments {
                        let path = try? AttachmentStore.save(data: raw.data, filename: raw.filename, messageID: id)
                        attachments.append(
                            MailAttachment(
                                id: UUID(),
                                filename: raw.filename,
                                mimeType: raw.mimeType,
                                byteSize: raw.data.count,
                                localPath: path
                            )
                        )
                    }
                    let remoteID = "\(provider.rawValue)|\(info.name)|\(item.uid)"
                    let msg = MailMessage(
                        id: id,
                        accountID: accountID,
                        folderID: folderID,
                        fromName: item.fromName,
                        fromAddress: item.fromAddress,
                        toAddresses: item.toAddresses.isEmpty ? [email] : item.toAddresses,
                        ccAddresses: item.ccAddresses,
                        subject: item.subject,
                        snippet: item.snippet,
                        body: item.body,
                        isHTML: item.isHTML,
                        receivedAt: item.date,
                        isRead: item.isRead,
                        isFlagged: item.isFlagged,
                        attachments: attachments,
                        deliveredTo: email,
                        disposition: .normal,
                        isDraft: info.kind == .drafts,
                        remoteID: remoteID,
                        internetMessageId: item.internetMessageId
                    )
                    all.append(msg)
                }
                // Persist high-water even when the change set is empty (fast no-op Sync).
                let highest = max(maxUID, (state.uidNext > 0 ? state.uidNext &- 1 : 0))
                if state.uidValidity != 0 {
                    MailMessageCache.saveIMAPCursor(
                        provider: provider.rawValue,
                        email: email,
                        mailbox: info.name,
                        uidValidity: state.uidValidity,
                        highestUID: highest
                    )
                }
                _ = usedIncremental
            } catch {
                folderErrors.append("\(info.ladderName): \(error.localizedDescription)")
                continue
            }
        }
        await imap.logout()

        let usedIncremental = hydrateFolders == 0 && incrementalFolders > 0 && folderErrors.isEmpty
        // Hydrate merges into the durable local index — never folder-replace/prune.
        let allowsFolderReplace = false
        var status: String
        if usedIncremental && all.isEmpty {
            status = "UID sync — no new mail (\(provider.displayName), \(picked.count) folders)"
        } else if usedIncremental {
            status = "UID sync — \(all.count) new from \(incrementalFolders) folders (\(provider.displayName))"
        } else {
            status = "Synced \(all.count) messages from \(picked.count) folders (\(provider.displayName))"
        }
        if !folderErrors.isEmpty {
            status += " — partial: " + folderErrors.prefix(3).joined(separator: " | ")
        }
        let result = IMAPSyncResult(
            foldersFetched: picked.count,
            messagesFetched: all.count,
            status: status,
            allowsFolderReplace: allowsFolderReplace,
            usedIncremental: usedIncremental
        )
        return (all, listed, result)
    }

    /// Mailboxes worth hydrating beyond Inbox/Sent/Drafts (Gmail Starred/Important + user labels).
    /// Caps custom-label hydrate so Sync stays responsive. Skips All Mail / Spam by default.
    static func defaultMessageSyncTargets(
        listed: [IMAPFolderInfo],
        accountID: UUID,
        excluding: Set<String> = [],
        customCap: Int = 16
    ) -> [(IMAPFolderInfo, UUID)] {
        var out: [(IMAPFolderInfo, UUID)] = []
        var customCount = 0

        let usefulSystemLeaves: Set<String> = ["STARRED", "IMPORTANT"]
        for info in listed {
            guard info.isSelectable, !excluding.contains(info.name), !info.isGmailAllMail else { continue }
            if info.kind == .junk { continue } // Spam optional — show in ladder, skip hydrate flood
            if info.kind == .inbox || info.kind == .sent || info.kind == .drafts
                || info.kind == .trash || info.kind == .archive {
                continue // already handled via folderIDs
            }
            let leaf = info.ladderName.uppercased()
            if info.isGmailSystemMailbox {
                guard usefulSystemLeaves.contains(leaf) else { continue }
                out.append((info, stableFolderID(accountID: accountID, mailbox: info.name)))
                continue
            }
            // User labels (not under [Gmail]/)
            guard customCount < customCap else { continue }
            customCount += 1
            out.append((info, stableFolderID(accountID: accountID, mailbox: info.name)))
        }
        return out
    }

    /// Stable local folder UUID for an IMAP mailbox name (Gmail labels).
    static func stableFolderID(accountID: UUID, mailbox: String) -> UUID {
        let raw = "rapsodee.folder|\(accountID.uuidString.lowercased())|\(mailbox)"
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(raw.utf8)
        for (i, b) in bytes.enumerated() {
            hash[i % 16] ^= b &+ UInt8(i % 251)
        }
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

        /// Parse `provider|mailbox|uid` remoteID and delete on the server (move to Trash when possible).
    static func deleteRemoteMessage(
        provider: MailIMAPProvider,
        email: String,
        password: String,
        remoteID: String
    ) async throws {
        let parts = remoteID.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else {
            throw MailNetError.unexpected("Bad IMAP remoteID for delete")
        }
        // remoteID format: provider|mailbox|uid — mailbox may itself contain "|" rarely; uid is last.
        let uidString = parts.last!
        guard let uid = UInt32(uidString) else {
            throw MailNetError.unexpected("Bad IMAP UID in remoteID")
        }
        let mailbox = parts.dropFirst().dropLast().joined(separator: "|")
        guard !mailbox.isEmpty else {
            throw MailNetError.unexpected("Missing mailbox in remoteID")
        }

        let imap = SimpleIMAPClient()
        try await imap.connect(host: provider.imapHost, port: provider.imapPort)
        try await imap.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        let trash = try await imap.resolveTrashMailbox()
        try await imap.deleteUID(uid, mailbox: mailbox, trashMailbox: trash)
        await imap.logout()
    }

    static func send(
        provider: MailIMAPProvider,
        email: String,
        password: String,
        draft: ComposeDraft,
        signature: String?,
        signatureLogoPath: String? = nil
    ) async throws {
        let rendered = MailSignatureFormatting.outboundBody(
            draftBody: draft.body,
            signature: signature,
            logoPath: signatureLogoPath
        )
        let plain = MailSignatureFormatting.appendPlainIfNeeded(body: draft.body, signature: signature)
        let to = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cc = draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let smtp = SimpleSMTPClient()
        try await connectSMTP(smtp, provider: provider)
        try await smtp.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        var outbound: [SimpleSMTPClient.OutboundAttachment] = []
        for att in draft.attachments {
            if let data = AttachmentStore.load(path: att.localPath) {
                outbound.append(.init(filename: att.filename, mimeType: att.mimeType, data: data))
            }
        }
        try await smtp.send(
            from: draft.fromAddress.isEmpty ? email : draft.fromAddress,
            to: to,
            cc: cc,
            subject: draft.subject,
            body: plain,
            htmlBody: rendered.isHTML ? rendered.content : nil,
            attachments: outbound
        )
        await smtp.quit()
    }

    static func stableMessageID(provider: MailIMAPProvider, email: String, mailbox: String, uid: UInt32) -> UUID {
        let raw = "\(provider.messageIDNamespace)|\(email.lowercased())|\(mailbox)|\(uid)"
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(raw.utf8)
        for (i, b) in bytes.enumerated() {
            hash[i % 16] ^= b &+ UInt8(i % 251)
        }
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

    private static func connectSMTP(_ smtp: SimpleSMTPClient, provider: MailIMAPProvider) async throws {
        if provider.smtpUsesStartTLS {
            do {
                try await smtp.connect(host: provider.smtpHost, port: provider.smtpPort, startTLS: true)
            } catch {
                // Fallback: some tenants accept implicit TLS on 465.
                try await smtp.connect(host: provider.smtpHost, port: 465, startTLS: false)
            }
        } else {
            try await smtp.connect(host: provider.smtpHost, port: provider.smtpPort, startTLS: false)
        }
    }
}
