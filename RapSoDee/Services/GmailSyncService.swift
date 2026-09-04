import Foundation

enum GmailDefaults {
    static let emailKey = "rapSoDee.gmail.email"
    static let accountIDKey = "rapSoDee.gmail.accountID"
    static let promptDismissedKey = "rapSoDee.gmail.promptDismissed"
    static let defaultEmail = "ci.derekbrown@gmail.com"
    static let recentLimit = 50
    static let tintHex = "EA4335"
}

struct GmailSyncResult {
    var foldersFetched: Int
    var messagesFetched: Int
    var status: String
}

enum GmailSyncService {
    static func storedEmail() -> String? {
        UserDefaults.standard.string(forKey: GmailDefaults.emailKey)
    }

    static func storedAccountID() -> UUID? {
        if let s = UserDefaults.standard.string(forKey: GmailDefaults.accountIDKey) {
            return UUID(uuidString: s)
        }
        return nil
    }

    static func rememberAccount(email: String, id: UUID) {
        UserDefaults.standard.set(email, forKey: GmailDefaults.emailKey)
        UserDefaults.standard.set(id.uuidString, forKey: GmailDefaults.accountIDKey)
    }

    static func clearRememberedAccount() {
        UserDefaults.standard.removeObject(forKey: GmailDefaults.emailKey)
        UserDefaults.standard.removeObject(forKey: GmailDefaults.accountIDKey)
    }

    static func hasKeychainCredentials(email: String? = nil) -> Bool {
        let address = email ?? storedEmail() ?? GmailDefaults.defaultEmail
        return KeychainCredentialStore.hasCredentials(forEmail: address)
    }

    static func testConnection(email: String, password: String) async throws {
        let imap = SimpleIMAPClient()
        try await imap.connect()
        try await imap.login(email: email, password: password)
        _ = try await imap.listFolders()
        await imap.logout()

        let smtp = SimpleSMTPClient()
        try await smtp.connect()
        try await smtp.login(email: email, password: password)
        await smtp.quit()
    }

    /// Fetch Inbox / Sent / Drafts (when listable) into plain structs for the store to merge.
    static func sync(email: String, password: String, accountID: UUID, folderIDs: GmailFolderIDs) async throws -> (messages: [MailMessage], remoteFolders: [IMAPFolderInfo], result: GmailSyncResult) {
        let imap = SimpleIMAPClient()
        try await imap.connect()
        try await imap.login(email: email, password: password)
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
        for (info, folderID) in picked {
            let fetched = try await imap.fetchRecent(mailbox: info.name, limit: GmailDefaults.recentLimit)
            for item in fetched {
                let id = stableMessageID(email: email, mailbox: info.name, uid: item.uid)
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
                    deliveredTo: email,
                    disposition: .normal,
                    isDraft: info.kind == .drafts
                )
                all.append(msg)
            }
        }
        await imap.logout()

        let result = GmailSyncResult(
            foldersFetched: picked.count,
            messagesFetched: all.count,
            status: "Synced \(all.count) messages from \(picked.count) folders"
        )
        return (all, listed, result)
    }

    static func send(email: String, password: String, draft: ComposeDraft, signature: String?) async throws {
        var body = draft.body
        if let signature, !signature.isEmpty, !body.contains(signature) {
            body += "\n\n--\n" + signature
        }
        let to = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cc = draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let smtp = SimpleSMTPClient()
        try await smtp.connect()
        try await smtp.login(email: email, password: password)
        try await smtp.send(
            from: draft.fromAddress.isEmpty ? email : draft.fromAddress,
            to: to,
            cc: cc,
            subject: draft.subject,
            body: body
        )
        await smtp.quit()
    }

    static func stableMessageID(email: String, mailbox: String, uid: UInt32) -> UUID {
        let raw = "rapsodee.gmail|\(email.lowercased())|\(mailbox)|\(uid)"
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
}

struct GmailFolderIDs {
    var inbox: UUID
    var sent: UUID
    var drafts: UUID
    var archive: UUID
    var trash: UUID
}
