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
    static let recentLimit = MailIMAPProvider.office365.recentLimit
    static let tintHex = MailIMAPProvider.office365.tintHex
}

enum Office365SyncService {
    private static let provider = MailIMAPProvider.office365

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
