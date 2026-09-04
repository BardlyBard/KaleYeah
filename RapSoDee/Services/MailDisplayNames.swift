import Foundation

/// Persisted friendly overrides for account and folder display labels.
enum MailDisplayNames {
    private static let accountKey = "rapSoDee.accountDisplayNames"
    private static let folderKey = "rapSoDee.folderDisplayNames"

    static func accountName(for id: UUID) -> String? {
        dictionary(for: accountKey)[id.uuidString]
    }

    static func setAccountName(_ name: String, for id: UUID) {
        var dict = dictionary(for: accountKey)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: id.uuidString)
        } else {
            dict[id.uuidString] = trimmed
        }
        UserDefaults.standard.set(dict, forKey: accountKey)
    }

    static func folderName(for id: UUID) -> String? {
        dictionary(for: folderKey)[id.uuidString]
    }

    static func setFolderName(_ name: String, for id: UUID) {
        var dict = dictionary(for: folderKey)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: id.uuidString)
        } else {
            dict[id.uuidString] = trimmed
        }
        UserDefaults.standard.set(dict, forKey: folderKey)
    }

    private static func dictionary(for key: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}
