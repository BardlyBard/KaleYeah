import Foundation
import Security

/// Stores mailbox / app passwords in the macOS Keychain only — never in source or UserDefaults.
enum KeychainCredentialStore {
    private static let service = "local.rapsodee.mail"
    /// Pre–Microsoft 365 service name; still read for Gmail credentials saved earlier.
    private static let legacyGmailService = "local.rapsodee.mail.gmail"

    /// Updates the password in place when the item already exists so Keychain Access
    /// Control (Always Allow / ACL) is preserved. Only SecItemAdd when missing —
    /// never delete-then-add, which recreates the item with default Confirm prompts.
    static func savePassword(_ password: String, forEmail email: String) throws {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Value-only update preserves existing ACL / accessibility / access control.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func password(forEmail email: String) -> String? {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let data = copyPasswordData(service: service, account: account) {
            return String(data: data, encoding: .utf8)
        }
        if let data = copyPasswordData(service: legacyGmailService, account: account) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func deletePassword(forEmail email: String) {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for svc in [service, legacyGmailService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    static func hasCredentials(forEmail email: String) -> Bool {
        password(forEmail: email) != nil
    }

    private static func copyPasswordData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error (\(status))"
            }
        }
    }
}
