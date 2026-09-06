import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

extension UTType {
    /// In-app drag of one or more mail messages for filing onto the ladder.
    static let rapSoDeeMailFile = UTType(exportedAs: "local.rapsodee.mail.file-drag")
}

/// Codable payload transferred while dragging mail onto ladder folders/labels.
struct MailFileDragPayload: Codable, Transferable, Hashable, Sendable {
    let messageIDs: [UUID]
    let accountID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rapSoDeeMailFile)
    }
}

/// Tracks the active in-app mail drag so ladder rows can highlight only valid same-account targets.
@Observable
final class MailDragController {
    private(set) var isDragging = false
    private(set) var messageIDs: [UUID] = []
    private(set) var accountID: UUID?

#if os(macOS)
    @ObservationIgnored private var mouseUpMonitor: Any?
#endif

    /// Folder kinds that accept a file drop (matches FilePickerSheet destinations). No trash/delete.
    static func isFileableKind(_ kind: FolderKind) -> Bool {
        switch kind {
        case .inbox, .archive, .custom:
            return true
        case .sent, .drafts, .trash, .snoozed, .approve, .junk:
            return false
        }
    }

    func begin(messageIDs: [UUID], accountID: UUID) {
        self.messageIDs = messageIDs
        self.accountID = accountID
        self.isDragging = true
#if os(macOS)
        clearMouseUpMonitor()
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            // End session after the drag gesture completes (drop or cancel).
            DispatchQueue.main.async {
                self?.end()
            }
            return event
        }
#endif
    }

    func end() {
        guard isDragging || !messageIDs.isEmpty || accountID != nil else { return }
        isDragging = false
        messageIDs = []
        accountID = nil
#if os(macOS)
        clearMouseUpMonitor()
#endif
    }

    /// Same-account + fileable kind. Smart ladder rows (nil account) never accept.
    func canDrop(onto folder: MailFolder) -> Bool {
        guard isDragging, let dragAccount = accountID else { return false }
        guard let folderAccount = folder.accountID, folderAccount == dragAccount else { return false }
        return Self.isFileableKind(folder.kind)
    }

    func canDrop(payload: MailFileDragPayload, onto folder: MailFolder) -> Bool {
        guard let folderAccount = folder.accountID, folderAccount == payload.accountID else { return false }
        guard !payload.messageIDs.isEmpty else { return false }
        return Self.isFileableKind(folder.kind)
    }

#if os(macOS)
    private func clearMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }
#endif
}
