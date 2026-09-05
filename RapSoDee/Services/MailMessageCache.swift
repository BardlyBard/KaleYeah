import Foundation

/// Disk cache for live mail so quit/relaunch shows the last sync without an empty flash.
/// Secrets stay in Keychain / MSAL — this file holds message metadata + bodies only.
enum MailMessageCache {
    private static let folderName = "RapSoDeeMailCache"
    private static let messagesFile = "messages.json"
    private static let tombstonesFile = "deletedRemoteIDs.json"
    /// Soft cap so huge inboxes never block launch.
    static let maxCachedMessages = 200
    private static let maxBodyChars = 120_000
    private static let loadBudgetBytes = 12 * 1024 * 1024

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

    struct Snapshot: Codable {
        var savedAt: Date
        var messages: [MailMessage]
    }

    /// Load recent messages from disk. Returns empty on miss/corruption; never throws to callers.
    static func loadMessages() -> [MailMessage] {
        let url = messagesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= loadBudgetBytes else {
            // Oversized cache — leave it; next save will rewrite a bounded window.
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [] }
        return Array(snapshot.messages.prefix(maxCachedMessages))
    }

    /// Persist a recent window after a successful sync / local delete.
    static func saveMessages(_ messages: [MailMessage]) {
        var trimmed = messages.sorted { $0.receivedAt > $1.receivedAt }
        if trimmed.count > maxCachedMessages {
            trimmed = Array(trimmed.prefix(maxCachedMessages))
        }
        trimmed = trimmed.map { truncateBodyIfNeeded($0) }
        let snapshot = Snapshot(savedAt: Date(), messages: trimmed)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: messagesURL, options: .atomic)
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

    private static func truncateBodyIfNeeded(_ message: MailMessage) -> MailMessage {
        guard message.body.count > maxBodyChars else { return message }
        var copy = message
        copy.body = String(message.body.prefix(maxBodyChars)) + "\n\n[…cached body truncated…]"
        return copy
    }
}
