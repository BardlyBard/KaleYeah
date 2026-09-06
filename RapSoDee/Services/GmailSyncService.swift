import Foundation

enum GmailDefaults {
    static let emailKey = MailIMAPProvider.gmail.userDefaultsEmailKey
    static let accountIDKey = MailIMAPProvider.gmail.userDefaultsAccountIDKey
    static let promptDismissedKey = MailIMAPProvider.gmail.promptDismissedKey
    static let defaultEmail = MailIMAPProvider.gmail.defaultEmail
    static let recentLimit = MailIMAPProvider.gmail.recentLimit
    static let tintHex = MailIMAPProvider.gmail.tintHex
}

typealias GmailSyncResult = IMAPSyncResult
typealias GmailFolderIDs = IMAPFolderIDs

enum GmailSyncService {
    private static let provider = MailIMAPProvider.gmail

    static func storedEmail() -> String? {
        IMAPAccountSyncService.storedEmail(provider: provider)
    }

    static func storedAccountID() -> UUID? {
        IMAPAccountSyncService.storedAccountID(provider: provider)
    }

    static func rememberAccount(email: String, id: UUID) {
        IMAPAccountSyncService.rememberAccount(provider: provider, email: email, id: id)
    }

    static func clearRememberedAccount() {
        IMAPAccountSyncService.clearRememberedAccount(provider: provider)
    }

    static func hasKeychainCredentials(email: String? = nil) -> Bool {
        IMAPAccountSyncService.hasKeychainCredentials(provider: provider, email: email)
    }

    static func testConnection(email: String, password: String) async throws {
        try await IMAPAccountSyncService.testConnection(provider: provider, email: email, password: password)
    }

    static func sync(email: String, password: String, accountID: UUID, folderIDs: GmailFolderIDs) async throws -> (messages: [MailMessage], remoteFolders: [IMAPFolderInfo], result: GmailSyncResult) {
        try await IMAPAccountSyncService.sync(
            provider: provider,
            email: email,
            password: password,
            accountID: accountID,
            folderIDs: folderIDs
        )
    }

    static func deleteRemoteMessage(email: String, password: String, remoteID: String) async throws {
        try await IMAPAccountSyncService.deleteRemoteMessage(
            provider: provider,
            email: email,
            password: password,
            remoteID: remoteID
        )
    }

    static func send(email: String, password: String, draft: ComposeDraft, signature: String?) async throws {
        try await IMAPAccountSyncService.send(
            provider: provider,
            email: email,
            password: password,
            draft: draft,
            signature: signature
        )
    }

    static func stableMessageID(email: String, mailbox: String, uid: UInt32) -> UUID {
        IMAPAccountSyncService.stableMessageID(provider: provider, email: email, mailbox: mailbox, uid: uid)
    }
}

enum Office365Defaults {
    static let emailKey = MailIMAPProvider.office365.userDefaultsEmailKey
    static let accountIDKey = MailIMAPProvider.office365.userDefaultsAccountIDKey
    static let promptDismissedKey = MailIMAPProvider.office365.promptDismissedKey
    static let defaultEmail = MailIMAPProvider.office365.defaultEmail
    static let calliopeEmail = MSALAppConfig.calliopeEmail
    static let recentLimit = MailIMAPProvider.office365.recentLimit
    static let tintHex = MailIMAPProvider.office365.tintHex
    /// Distinct tint so Callie's mailbox is obvious next to Derek's blue.
    static let calliopeTintHex = "F28C28"
}

struct RememberedOffice365Account: Codable, Equatable, Hashable {
    var email: String
    var id: UUID
}

/// Account shell persistence for Microsoft 365. Mail sync/send use MSAL + Graph (see MSALAuthService / MicrosoftGraphMailService).
/// Supports multiple live mailboxes (Derek + Calliope) without overwriting each other.
/// IMAP helpers remain for reference; Settings no longer uses basic auth (disabled by Microsoft).
enum Office365SyncService {
    private static let provider = MailIMAPProvider.office365
    private static let accountsKey = "rapSoDee.office365.accounts"

    static func storedEmail() -> String? {
        rememberedAccounts().first?.email ?? IMAPAccountSyncService.storedEmail(provider: provider)
    }

    static func storedAccountID() -> UUID? {
        rememberedAccounts().first?.id ?? IMAPAccountSyncService.storedAccountID(provider: provider)
    }

    static func rememberedAccounts() -> [RememberedOffice365Account] {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([RememberedOffice365Account].self, from: data),
           !decoded.isEmpty {
            return uniqueAccounts(decoded)
        }
        // Migrate legacy single-account keys.
        if let email = IMAPAccountSyncService.storedEmail(provider: provider) {
            let id = IMAPAccountSyncService.storedAccountID(provider: provider) ?? UUID()
            let migrated = [RememberedOffice365Account(email: email, id: id)]
            saveRememberedAccounts(migrated)
            return migrated
        }
        return []
    }

    static func rememberAccount(email: String, id: UUID) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = rememberedAccounts()
        let lower = trimmed.lowercased()
        if let idx = list.firstIndex(where: { $0.email.lowercased() == lower }) {
            list[idx] = RememberedOffice365Account(email: trimmed, id: id)
        } else {
            list.append(RememberedOffice365Account(email: trimmed, id: id))
        }
        saveRememberedAccounts(list)
        // Keep legacy keys pointing at primary (first) for older readers.
        if let primary = list.first {
            IMAPAccountSyncService.rememberAccount(provider: provider, email: primary.email, id: primary.id)
        }
    }

    static func forgetAccount(email: String) {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = rememberedAccounts().filter { $0.email.lowercased() != lower }
        saveRememberedAccounts(list)
        if let primary = list.first {
            IMAPAccountSyncService.rememberAccount(provider: provider, email: primary.email, id: primary.id)
        } else {
            IMAPAccountSyncService.clearRememberedAccount(provider: provider)
        }
    }

    static func clearRememberedAccount() {
        UserDefaults.standard.removeObject(forKey: accountsKey)
        IMAPAccountSyncService.clearRememberedAccount(provider: provider)
    }

    private static func saveRememberedAccounts(_ accounts: [RememberedOffice365Account]) {
        let unique = uniqueAccounts(accounts)
        if unique.isEmpty {
            UserDefaults.standard.removeObject(forKey: accountsKey)
        } else if let data = try? JSONEncoder().encode(unique) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    private static func uniqueAccounts(_ accounts: [RememberedOffice365Account]) -> [RememberedOffice365Account] {
        var seen = Set<String>()
        var out: [RememberedOffice365Account] = []
        for account in accounts {
            let key = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(RememberedOffice365Account(email: account.email.trimmingCharacters(in: .whitespacesAndNewlines), id: account.id))
        }
        return out
    }

    static func hasKeychainCredentials(email: String? = nil) -> Bool {
        IMAPAccountSyncService.hasKeychainCredentials(provider: provider, email: email)
    }

    static func testConnection(email: String, password: String) async throws {
        try await IMAPAccountSyncService.testConnection(provider: provider, email: email, password: password)
    }

    static func sync(email: String, password: String, accountID: UUID, folderIDs: IMAPFolderIDs) async throws -> (messages: [MailMessage], remoteFolders: [IMAPFolderInfo], result: IMAPSyncResult) {
        try await IMAPAccountSyncService.sync(
            provider: provider,
            email: email,
            password: password,
            accountID: accountID,
            folderIDs: folderIDs
        )
    }

    static func send(email: String, password: String, draft: ComposeDraft, signature: String?) async throws {
        try await IMAPAccountSyncService.send(
            provider: provider,
            email: email,
            password: password,
            draft: draft,
            signature: signature
        )
    }
}
