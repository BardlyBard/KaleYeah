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

    static func sync(
        provider: MailIMAPProvider,
        email: String,
        password: String,
        accountID: UUID,
        folderIDs: IMAPFolderIDs
    ) async throws -> (messages: [MailMessage], remoteFolders: [IMAPFolderInfo], result: IMAPSyncResult) {
        let imap = SimpleIMAPClient()
        try await imap.connect(host: provider.imapHost, port: provider.imapPort)
        try await imap.login(email: email, password: password, stripSpaces: provider.stripPasswordSpaces)
        let listed = try await imap.listFolders()

        var picked: [(IMAPFolderInfo, UUID)] = []
        if let inbox = listed.first(where: { $0.kind == .inbox }) ?? listed.first(where: { $0.name.uppercased() == "INBOX" }) {
            picked.append((inbox, folderIDs.inbox))
        }
        if let sent = listed.first(where: { $0.kind == .sent }) {
            picked.append((sent, folderIDs.sent))
        }
        if let drafts = listed.first(where: { $0.kind == .drafts }) {
            picked.append((drafts, folderIDs.drafts))
        }

        var all: [MailMessage] = []
        var incrementalFolders = 0
        var hydrateFolders = 0
        for (info, folderID) in picked {
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
        }
        await imap.logout()

        let usedIncremental = hydrateFolders == 0 && incrementalFolders > 0
        // Hydrate merges into the durable local index — never folder-replace/prune.
        let allowsFolderReplace = false
        let status: String
        if usedIncremental && all.isEmpty {
            status = "UID sync — no new mail (\(provider.displayName))"
        } else if usedIncremental {
            status = "UID sync — \(all.count) new from \(incrementalFolders) folders (\(provider.displayName))"
        } else {
            status = "Synced \(all.count) messages from \(picked.count) folders (\(provider.displayName))"
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
        signature: String?
    ) async throws {
        var body = draft.body
        if let signature, !signature.isEmpty, !body.contains(signature) {
            body += "\n\n--\n" + signature
        }
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
            body: body,
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
