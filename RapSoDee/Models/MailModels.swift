import Foundation
import SwiftUI

struct MailAccount: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var email: String
    var tintHex: String
    var signature: String
    var includeInUnifiedInbox: Bool
    var isCalliope: Bool
    var sortOrder: Int
    var inboxPinned: Bool
    /// Live Gmail (IMAP/SMTP via app password). Demo accounts stay false.
    var isLiveGmail: Bool
    /// Live Microsoft 365 / GoDaddy Email Essentials (IMAP/SMTP via mailbox password).
    var isLiveOffice365: Bool

    var isLiveIMAP: Bool { isLiveGmail || isLiveOffice365 }

    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        tintHex: String,
        signature: String = "",
        includeInUnifiedInbox: Bool = true,
        isCalliope: Bool = false,
        sortOrder: Int = 0,
        inboxPinned: Bool = true,
        isLiveGmail: Bool = false,
        isLiveOffice365: Bool = false
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.tintHex = tintHex
        self.signature = signature
        self.includeInUnifiedInbox = includeInUnifiedInbox
        self.isCalliope = isCalliope
        self.sortOrder = sortOrder
        self.inboxPinned = inboxPinned
        self.isLiveGmail = isLiveGmail
        self.isLiveOffice365 = isLiveOffice365
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email, tintHex, signature, includeInUnifiedInbox, isCalliope, sortOrder, inboxPinned, isLiveGmail, isLiveOffice365
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        tintHex = try c.decode(String.self, forKey: .tintHex)
        signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
        includeInUnifiedInbox = try c.decodeIfPresent(Bool.self, forKey: .includeInUnifiedInbox) ?? true
        isCalliope = try c.decodeIfPresent(Bool.self, forKey: .isCalliope) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        inboxPinned = try c.decodeIfPresent(Bool.self, forKey: .inboxPinned) ?? true
        isLiveGmail = try c.decodeIfPresent(Bool.self, forKey: .isLiveGmail) ?? false
        isLiveOffice365 = try c.decodeIfPresent(Bool.self, forKey: .isLiveOffice365) ?? false
    }
}

enum FolderKind: String, Codable, Hashable, CaseIterable, Sendable {
    case inbox, sent, drafts, archive, trash, snoozed, approve, junk, custom
}

struct MailFolder: Identifiable, Hashable, Codable {
    var id: UUID
    var accountID: UUID?
    var name: String
    var kind: FolderKind
    var sortOrder: Int
    var isPinned: Bool
    var isSmart: Bool
    /// Graph mailFolder id, or well-known name (`inbox`, `sentitems`, …) for API calls / import.
    var remoteID: String?
    /// Local parent folder when nesting customs under another ladder folder.
    var parentFolderID: UUID?

    init(
        id: UUID = UUID(),
        accountID: UUID? = nil,
        name: String,
        kind: FolderKind,
        sortOrder: Int = 0,
        isPinned: Bool = false,
        isSmart: Bool = false,
        remoteID: String? = nil,
        parentFolderID: UUID? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.kind = kind
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.isSmart = isSmart
        self.remoteID = remoteID
        self.parentFolderID = parentFolderID
    }

    enum CodingKeys: String, CodingKey {
        case id, accountID, name, kind, sortOrder, isPinned, isSmart, remoteID, parentFolderID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(FolderKind.self, forKey: .kind)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isSmart = try c.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
        parentFolderID = try c.decodeIfPresent(UUID.self, forKey: .parentFolderID)
    }
}

struct MailAttachment: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var filename: String
    var mimeType: String
    var byteSize: Int
    var demoPayloadHint: String?
    /// Absolute path under AttachmentStore when content is cached locally.
    var localPath: String?
    /// Provider-specific attachment id (e.g. Graph) for optional re-fetch.
    var remoteID: String?

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteSize: Int,
        demoPayloadHint: String? = nil,
        localPath: String? = nil,
        remoteID: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.demoPayloadHint = demoPayloadHint
        self.localPath = localPath
        self.remoteID = remoteID
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, byteSize, demoPayloadHint, localPath, remoteID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        byteSize = try c.decode(Int.self, forKey: .byteSize)
        demoPayloadHint = try c.decodeIfPresent(String.self, forKey: .demoPayloadHint)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
    }

    var isPreviewable: Bool {
        let blocked = ["exe", "js", "html", "htm", "msi", "bat", "cmd", "scr", "vbs"]
        let ext = (filename as NSString).pathExtension.lowercased()
        if blocked.contains(ext) { return false }
        if mimeType.contains("javascript") || mimeType.contains("html") { return false }
        return mimeType.hasPrefix("image/") || mimeType == "application/pdf"
            || ["png", "jpg", "jpeg", "gif", "webp", "pdf"].contains(ext)
    }

    var isBlockedType: Bool {
        let blocked = ["exe", "js", "html", "htm", "msi", "bat", "cmd", "scr", "vbs"]
        let ext = (filename as NSString).pathExtension.lowercased()
        return blocked.contains(ext)
            || mimeType.contains("javascript")
            || mimeType.contains("html")
    }

    var hasLocalContent: Bool {
        guard let localPath, !localPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: localPath)
    }
}

struct MailFlag: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    /// Default named flags (Apple Mail–style palette). Editable in Settings.
    static let defaults: [MailFlag] = [
        MailFlag(name: "Red", colorHex: "E23B3B"),
        MailFlag(name: "Orange", colorHex: "E07A3D"),
        MailFlag(name: "Yellow", colorHex: "D4A017"),
        MailFlag(name: "Green", colorHex: "1F8A5B"),
        MailFlag(name: "Blue", colorHex: "3B7DD8"),
        MailFlag(name: "Purple", colorHex: "7B5EA7"),
        MailFlag(name: "Gray", colorHex: "8E8E93"),
    ]
}

enum MessageDisposition: String, Codable, Hashable, Sendable {
    case normal, pendingApproval, approved, rejected
}

struct MailMessage: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var accountID: UUID
    var folderID: UUID
    var fromName: String
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var subject: String
    var snippet: String
    var body: String
    /// True when `body` is HTML suitable for WKWebView rendering.
    var isHTML: Bool
    var receivedAt: Date
    var isRead: Bool
    var isFlagged: Bool
    var flagID: UUID?
    var snoozeUntil: Date?
    var attachments: [MailAttachment]
    var deliveredTo: String
    var disposition: MessageDisposition
    var isDraft: Bool
    /// Provider-stable id (Graph message id, or IMAP `provider|mailbox|uid`).
    var remoteID: String?
    /// RFC 5322 Message-ID when available (Graph `internetMessageId` / IMAP Message-ID).
    var internetMessageId: String?

    init(
        id: UUID = UUID(),
        accountID: UUID,
        folderID: UUID,
        fromName: String,
        fromAddress: String,
        toAddresses: [String],
        ccAddresses: [String] = [],
        subject: String,
        snippet: String,
        body: String,
        isHTML: Bool = false,
        receivedAt: Date = .now,
        isRead: Bool = false,
        isFlagged: Bool = false,
        flagID: UUID? = nil,
        snoozeUntil: Date? = nil,
        attachments: [MailAttachment] = [],
        deliveredTo: String,
        disposition: MessageDisposition = .normal,
        isDraft: Bool = false,
        remoteID: String? = nil,
        internetMessageId: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.folderID = folderID
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.isHTML = isHTML
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.flagID = flagID
        self.snoozeUntil = snoozeUntil
        self.attachments = attachments
        self.deliveredTo = deliveredTo
        self.disposition = disposition
        self.isDraft = isDraft
        self.remoteID = remoteID
        self.internetMessageId = internetMessageId
    }

    enum CodingKeys: String, CodingKey {
        case id, accountID, folderID, fromName, fromAddress, toAddresses, ccAddresses
        case subject, snippet, body, isHTML, receivedAt, isRead, isFlagged, flagID
        case snoozeUntil, attachments, deliveredTo, disposition, isDraft, remoteID, internetMessageId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        folderID = try c.decode(UUID.self, forKey: .folderID)
        fromName = try c.decode(String.self, forKey: .fromName)
        fromAddress = try c.decode(String.self, forKey: .fromAddress)
        toAddresses = try c.decode([String].self, forKey: .toAddresses)
        ccAddresses = try c.decodeIfPresent([String].self, forKey: .ccAddresses) ?? []
        subject = try c.decode(String.self, forKey: .subject)
        snippet = try c.decode(String.self, forKey: .snippet)
        body = try c.decode(String.self, forKey: .body)
        isHTML = try c.decodeIfPresent(Bool.self, forKey: .isHTML) ?? false
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        isRead = try c.decode(Bool.self, forKey: .isRead)
        isFlagged = try c.decode(Bool.self, forKey: .isFlagged)
        flagID = try c.decodeIfPresent(UUID.self, forKey: .flagID)
        snoozeUntil = try c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        attachments = try c.decodeIfPresent([MailAttachment].self, forKey: .attachments) ?? []
        deliveredTo = try c.decode(String.self, forKey: .deliveredTo)
        disposition = try c.decodeIfPresent(MessageDisposition.self, forKey: .disposition) ?? .normal
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID)
        internetMessageId = try c.decodeIfPresent(String.self, forKey: .internetMessageId)
    }
}

enum MessageSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case dateNewest, dateOldest, sender, subject
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateNewest: return "Date (newest)"
        case .dateOldest: return "Date (oldest)"
        case .sender: return "Sender"
        case .subject: return "Subject"
        }
    }
}

enum MessageFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, unread, flagged, hasAttachments
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .hasAttachments: return "Has attachments"
        }
    }
}

enum LadderSelection: Hashable {
    case unifiedInbox
    case approve
    case folder(UUID)
    case accountInbox(UUID)
}

enum ComposeMode: Hashable {
    case new
    case reply(MailMessage)
    case replyAll(MailMessage)
    case forward(MailMessage)
    case editDraft(MailMessage)
}

struct ComposeAttachment: Identifiable, Hashable, Codable {
    var id: UUID
    var filename: String
    var mimeType: String
    var byteSize: Int
    /// Cached absolute path (copied from NSOpenPanel selection).
    var localPath: String

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteSize: Int,
        localPath: String
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.localPath = localPath
    }
}

struct ComposeDraft: Identifiable, Hashable {
    var id = UUID()
    var mode: ComposeMode
    var fromAddress: String
    var to: String
    var cc: String
    var subject: String
    var body: String
    var accountID: UUID
    var popOut: Bool = false
    var attachments: [ComposeAttachment] = []
}
