import Foundation

/// Durable on-disk mail index under Application Support (sandbox `local.rapsodee.mail`).
/// Secrets stay in Keychain / MSAL — this tree holds message metadata, optional bodies, and sync cursors.
enum MailMessageCache {
    private static let folderName = "RapSoDeeMailCache"
    private static let messagesFile = "messages.json"
    private static let tombstonesFile = "deletedRemoteIDs.json"
    private static let syncStateFile = "syncState.json"
    private static let bodiesFolder = "bodies"

    /// Soft cap for the durable list index (metadata). Far above the old ~200 sync window.
    static let maxCachedMessages = 10_000
    /// Bodies in the index stay bounded; full HTML may live in sidecars after open.
    private static let maxBodyCharsInIndex = 80_000
    private static let loadBudgetBytes = 48 * 1024 * 1024

    private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var messagesURL: URL {
        rootDirectory.appendingPathComponent(messagesFile)
    }

    private static var tombstonesURL: URL {
        rootDirectory.appendingPathComponent(tombstonesFile)
    }

    private static var syncStateURL: URL {
        rootDirectory.appendingPathComponent(syncStateFile)
    }

    private static var bodiesDirectory: URL {
        let dir = rootDirectory.appendingPathComponent(bodiesFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Snapshot: Codable {
        var savedAt: Date
        var messages: [MailMessage]
        /// Account folders with stable UUIDs — required so relaunch can show cached mail
        /// immediately (message.folderID must match live ladder IDs).
        var folders: [MailFolder]

        enum CodingKeys: String, CodingKey {
            case savedAt, messages, folders
        }

        init(savedAt: Date, messages: [MailMessage], folders: [MailFolder] = []) {
            self.savedAt = savedAt
            self.messages = messages
            self.folders = folders
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            savedAt = try c.decode(Date.self, forKey: .savedAt)
            messages = try c.decode([MailMessage].self, forKey: .messages)
            folders = try c.decodeIfPresent([MailFolder].self, forKey: .folders) ?? []
        }
    }

    /// Graph delta links + IMAP UID high-water so Sync mostly pulls changes.
    struct SyncState: Codable, Equatable {
        /// `accountID.uuidString|mailboxKey` → Graph `@odata.deltaLink` URL.
        var graphDeltaLinks: [String: String]
        /// `provider|emailLower|mailbox` → IMAP UIDVALIDITY + highest synced UID.
        var imapFolders: [String: IMAPFolderCursor]

        init(graphDeltaLinks: [String: String] = [:], imapFolders: [String: IMAPFolderCursor] = [:]) {
            self.graphDeltaLinks = graphDeltaLinks
            self.imapFolders = imapFolders
        }

        struct IMAPFolderCursor: Codable, Equatable {
            var uidValidity: UInt32
            var highestUID: UInt32
        }

        static func graphKey(accountID: UUID, mailboxKey: String) -> String {
            "\(accountID.uuidString)|\(mailboxKey)"
        }

        static func imapKey(provider: String, email: String, mailbox: String) -> String {
            "\(provider)|\(email.lowercased())|\(mailbox)"
        }
    }

    // MARK: - Messages

    /// Load durable snapshot (messages + account folders). Empty on miss/corruption.
    static func loadSnapshot() -> Snapshot {
        let url = messagesURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(savedAt: .distantPast, messages: [], folders: [])
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= loadBudgetBytes else {
            return Snapshot(savedAt: .distantPast, messages: [], folders: [])
        }
        guard let data = try? Data(contentsOf: url) else {
            return Snapshot(savedAt: .distantPast, messages: [], folders: [])
        }
        guard var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(savedAt: .distantPast, messages: [], folders: [])
        }
        // Rehydrate full bodies from sidecars when present (list metadata always in index).
        for i in snapshot.messages.indices {
            if let body = loadBodySidecar(messageID: snapshot.messages[i].id), !body.text.isEmpty {
                if body.text.count > snapshot.messages[i].body.count {
                    snapshot.messages[i].body = body.text
                    snapshot.messages[i].isHTML = body.isHTML
                }
            }
            // Repair base64 / IMAP framing leaks left by older FETCH parsing.
            let repaired = MimeBodyParser.repairStoredBody(
                snapshot.messages[i].body,
                isHTML: snapshot.messages[i].isHTML
            )
            if repaired.body != snapshot.messages[i].body || repaired.isHTML != snapshot.messages[i].isHTML {
                snapshot.messages[i].body = repaired.body
                snapshot.messages[i].isHTML = repaired.isHTML
                if !repaired.body.isEmpty {
                    saveBodySidecar(
                        messageID: snapshot.messages[i].id,
                        text: repaired.body,
                        isHTML: repaired.isHTML
                    )
                }
            }
        }
        return snapshot
    }

    /// Load durable message index. Returns empty on miss/corruption; never throws to callers.
    static func loadMessages() -> [MailMessage] {
        loadSnapshot().messages
    }

    /// Account folders last persisted with the message index (stable UUIDs across relaunch).
    static func loadFolders() -> [MailFolder] {
        loadSnapshot().folders
    }

    /// Persist durable index after a successful sync / local delete / body load.
    /// Never clears an existing non-empty index when given an empty array (failed/empty fetch safety).
    static func saveMessages(_ messages: [MailMessage], folders: [MailFolder] = []) {
        if messages.isEmpty {
            // Do not wipe a populated on-disk index with an empty in-memory snapshot.
            if FileManager.default.fileExists(atPath: messagesURL.path),
               !loadMessages().isEmpty {
                return
            }
        }
        var trimmed = messages.sorted { $0.receivedAt > $1.receivedAt }
        if trimmed.count > maxCachedMessages {
            trimmed = Array(trimmed.prefix(maxCachedMessages))
        }
        // Keep metadata on disk; large bodies go to sidecars so relaunch list stays light.
        let indexRows: [MailMessage] = trimmed.map { message in
            if message.body.count > maxBodyCharsInIndex {
                saveBodySidecar(messageID: message.id, text: message.body, isHTML: message.isHTML)
                var copy = message
                // Keep snippet-sized preview in the index row.
                let preview = message.snippet.isEmpty
                    ? String(message.body.prefix(400))
                    : message.snippet
                copy.body = preview
                return copy
            }
            // Persist modest bodies in the index AND mirror to sidecar when HTML-ish / long.
            if message.body.count > max(message.snippet.count + 80, 400) {
                saveBodySidecar(messageID: message.id, text: message.body, isHTML: message.isHTML)
            }
            return message
        }
        // Prefer caller folders; if omitted, keep previously saved folder UUIDs so relaunch
        // rebind keeps working even when an older call site only passes messages.
        let foldersToSave: [MailFolder]
        if !folders.isEmpty {
            foldersToSave = folders.filter { $0.accountID != nil }
        } else {
            foldersToSave = loadFolders().filter { $0.accountID != nil }
        }
        let snapshot = Snapshot(savedAt: Date(), messages: indexRows, folders: foldersToSave)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: messagesURL, options: .atomic)
    }

    /// Persist a single message body after lazy load (open in reading pane).
    static func saveLoadedBody(messageID: UUID, text: String, isHTML: Bool) {
        guard !text.isEmpty else { return }
        saveBodySidecar(messageID: messageID, text: text, isHTML: isHTML)
    }

    static func loadDeletedRemoteIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: tombstonesURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func saveDeletedRemoteIDs(_ ids: Set<String>) {
        let list = Array(ids).sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: tombstonesURL, options: .atomic)
    }

    // MARK: - Sync state (delta / UID high-water)

    static func loadSyncState() -> SyncState {
        guard let data = try? Data(contentsOf: syncStateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    static func saveSyncState(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: syncStateURL, options: .atomic)
    }

    static func updateGraphDeltaLink(accountID: UUID, mailboxKey: String, deltaLink: String?) {
        var state = loadSyncState()
        let key = SyncState.graphKey(accountID: accountID, mailboxKey: mailboxKey)
        if let deltaLink, !deltaLink.isEmpty {
            state.graphDeltaLinks[key] = deltaLink
        } else {
            state.graphDeltaLinks.removeValue(forKey: key)
        }
        saveSyncState(state)
    }

    static func graphDeltaLink(accountID: UUID, mailboxKey: String) -> String? {
        let key = SyncState.graphKey(accountID: accountID, mailboxKey: mailboxKey)
        return loadSyncState().graphDeltaLinks[key]
    }

    static func imapCursor(provider: String, email: String, mailbox: String) -> SyncState.IMAPFolderCursor? {
        let key = SyncState.imapKey(provider: provider, email: email, mailbox: mailbox)
        return loadSyncState().imapFolders[key]
    }

    static func saveIMAPCursor(provider: String, email: String, mailbox: String, uidValidity: UInt32, highestUID: UInt32) {
        var state = loadSyncState()
        let key = SyncState.imapKey(provider: provider, email: email, mailbox: mailbox)
        state.imapFolders[key] = SyncState.IMAPFolderCursor(uidValidity: uidValidity, highestUID: highestUID)
        saveSyncState(state)
    }

    static func clearIMAPCursor(provider: String, email: String, mailbox: String) {
        var state = loadSyncState()
        let key = SyncState.imapKey(provider: provider, email: email, mailbox: mailbox)
        state.imapFolders.removeValue(forKey: key)
        saveSyncState(state)
    }

    // MARK: - Body sidecars

    private struct BodySidecar: Codable {
        var text: String
        var isHTML: Bool
    }

    private static func bodyURL(messageID: UUID) -> URL {
        bodiesDirectory.appendingPathComponent("\(messageID.uuidString).json")
    }

    private static func saveBodySidecar(messageID: UUID, text: String, isHTML: Bool) {
        let payload = BodySidecar(text: text, isHTML: isHTML)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: bodyURL(messageID: messageID), options: .atomic)
    }

    private static func loadBodySidecar(messageID: UUID) -> BodySidecar? {
        let url = bodyURL(messageID: messageID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BodySidecar.self, from: data)
    }
}
