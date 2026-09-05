import Foundation

/// Shared IMAP/SMTP endpoints for live mail accounts.
enum MailIMAPProvider: String, Codable, CaseIterable, Hashable {
    case gmail
    case office365

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .office365: return "Microsoft 365"
        }
    }

    var tintHex: String {
        switch self {
        case .gmail: return "EA4335"
        case .office365: return "0078D4"
        }
    }

    var defaultEmail: String {
        switch self {
        case .gmail: return "ci.derekbrown@gmail.com"
        case .office365: return "derek.brown@kaleyeahinspections.com"
        }
    }

    var imapHost: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .office365: return "outlook.office365.com"
        }
    }

    var imapPort: UInt16 { 993 }

    var smtpHost: String {
        switch self {
        case .gmail: return "smtp.gmail.com"
        case .office365: return "smtp.office365.com"
        }
    }

    /// Gmail uses implicit TLS on 465; Office 365 prefers 587 STARTTLS.
    var smtpPort: UInt16 {
        switch self {
        case .gmail: return 465
        case .office365: return 587
        }
    }

    var smtpUsesStartTLS: Bool {
        switch self {
        case .gmail: return false
        case .office365: return true
        }
    }

    /// Gmail App Passwords are often pasted with spaces; mailbox passwords must keep internal spaces.
    var stripPasswordSpaces: Bool {
        switch self {
        case .gmail: return true
        case .office365: return false
        }
    }

    var recentLimit: Int { 200 }

    var passwordPrompt: String {
        switch self {
        case .gmail: return "Gmail App Password"
        case .office365: return "Mailbox password"
        }
    }

    var userDefaultsEmailKey: String { "rapSoDee.\(rawValue).email" }
    var userDefaultsAccountIDKey: String { "rapSoDee.\(rawValue).accountID" }
    var promptDismissedKey: String { "rapSoDee.\(rawValue).promptDismissed" }

    var messageIDNamespace: String { "rapsodee.\(rawValue)" }
}

enum ProviderAccountDefaults {
    static let recentLimit = 200
}

struct IMAPFolderIDs: Sendable {
    var inbox: UUID
    var sent: UUID
    var drafts: UUID
    var archive: UUID
    var trash: UUID
}

struct IMAPSyncResult {
    var foldersFetched: Int
    var messagesFetched: Int
    var status: String
    /// When true, caller may replace folder contents from the fetch window.
    /// Incremental UID high-water sync sets this false (never prune on empty/partial).
    var allowsFolderReplace: Bool
    /// True when every mailbox used UID high-water (Sync with no new mail stays fast).
    var usedIncremental: Bool
}
