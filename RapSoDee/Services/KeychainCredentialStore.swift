import Foundation
import Security

/// Stores Gmail App Passwords in the macOS Keychain only — never in source or UserDefaults.
enum KeychainCredentialStore {
    private static let service = "local.rapsodee.mail.gmail"

    static func savePassword(_ password: String, forEmail email: String) throws {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func password(forEmail email: String) -> String? {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(forEmail email: String) {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasCredentials(forEmail email: String) -> Bool {
        password(forEmail: email) != nil
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
