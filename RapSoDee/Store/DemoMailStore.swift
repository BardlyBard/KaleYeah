import Foundation
import Observation
import SwiftUI

@Observable
final class DemoMailStore: MailStore {
    var accounts: [MailAccount] = []
    var folders: [MailFolder] = []
    var messages: [MailMessage] = []
    var flags: [MailFlag] = []
    /// Last flag chosen from a UI menu — used by the keyboard shortcut.
    var lastUsedFlagID: UUID?
    var sort: MessageSort = .dateNewest
    var filter: MessageFilter = .all
    var searchText: String = ""

    private let archiveFolderID = UUID()
    private let trashFolderID = UUID()
    private let snoozedFolderID = UUID()
    private let approveFolderID = UUID()
    private let junkFolderID = UUID()

    init() {
        seed()
    }

    func account(for id: UUID) -> MailAccount? { accounts.first { $0.id == id } }
    func folder(for id: UUID) -> MailFolder? { folders.first { $0.id == id } }

    func messages(for selection: LadderSelection) -> [MailMessage] {
        unsnoozeDue()
        var list: [MailMessage]
        switch selection {
        case .unifiedInbox:
            let included = Set(accounts.filter(\.includeInUnifiedInbox).map(\.id))
            let inboxIDs = Set(folders.filter { $0.kind == .inbox && ($0.accountID.map(included.contains) ?? false) }.map(\.id))
            list = messages.filter { inboxIDs.contains($0.folderID) && $0.snoozeUntil == nil }
        case .approve:
            let approveIDs = Set(folders.filter { $0.kind == .approve }.map(\.id))
            list = messages.filter { approveIDs.contains($0.folderID) || $0.disposition == .pendingApproval }
        case .folder(let id):
            if let folder = folder(for: id), folder.kind == .snoozed {
                list = messages.filter { $0.snoozeUntil != nil }
            } else {
                list = messages.filter { $0.folderID == id && $0.snoozeUntil == nil }
            }
        case .accountInbox(let accountID):
            let inboxIDs = Set(folders.filter { $0.kind == .inbox && $0.accountID == accountID }.map(\.id))
            list = messages.filter { inboxIDs.contains($0.folderID) && $0.snoozeUntil == nil }
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.fromName.lowercased().contains(q)
                    || $0.fromAddress.lowercased().contains(q)
                    || $0.subject.lowercased().contains(q)
                    || $0.snippet.lowercased().contains(q)
            }
        }

        switch filter {
        case .all: break
        case .unread: list = list.filter { !$0.isRead }
        case .flagged: list = list.filter { $0.isFlagged }
        case .hasAttachments: list = list.filter { !$0.attachments.isEmpty }
        }

        switch sort {
        case .dateNewest: list.sort { $0.receivedAt > $1.receivedAt }
        case .dateOldest: list.sort { $0.receivedAt < $1.receivedAt }
        case .sender: list.sort { $0.fromName.localizedCaseInsensitiveCompare($1.fromName) == .orderedAscending }
        case .subject: list.sort { $0.subject.localizedCaseInsensitiveCompare($1.subject) == .orderedAscending }
        }
        return list
    }

    func markRead(_ id: UUID, read: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].isRead = read
    }

    func toggleFlag(_ id: UUID, flagID: UUID?) {
        // Legacy entry point: explicit flagID sets; nil clears if flagged else applies first.
        if let flagID {
            setFlag(id, flagID: flagID)
        } else if messages.first(where: { $0.id == id })?.isFlagged == true {
            setFlag(id, flagID: nil)
        } else {
            setFlag(id, flagID: lastUsedFlagID ?? flags.first?.id)
        }
    }

    func setFlag(_ id: UUID, flagID: UUID?) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if let flagID {
            messages[i].isFlagged = true
            messages[i].flagID = flagID
            lastUsedFlagID = flagID
        } else {
            messages[i].isFlagged = false
            messages[i].flagID = nil
        }
    }

    func flagShortcut(_ id: UUID) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        if message.isFlagged {
            setFlag(id, flagID: nil)
        } else {
            setFlag(id, flagID: lastUsedFlagID ?? flags.first?.id)
        }
    }

    func archive(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if let dest = folders.first(where: { $0.kind == .archive && $0.accountID == messages[i].accountID }) {
            messages[i].folderID = dest.id
        } else {
            messages[i].folderID = archiveFolderID
        }
        messages[i].snoozeUntil = nil
    }

    func deleteRecessed(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if let dest = folders.first(where: { $0.kind == .trash && $0.accountID == messages[i].accountID }) {
            messages[i].folderID = dest.id
        } else {
            messages[i].folderID = trashFolderID
        }
    }

    func file(_ id: UUID, into folderID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].folderID = folderID
        messages[i].snoozeUntil = nil
    }

    func snooze(_ id: UUID, until: Date) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].snoozeUntil = until
        if let snoozed = folders.first(where: { $0.kind == .snoozed }) {
            messages[i].folderID = snoozed.id
        }
    }

    func unsnoozeDue() {
        let now = Date()
        for i in messages.indices {
            if let until = messages[i].snoozeUntil, until <= now {
                messages[i].snoozeUntil = nil
                if let inbox = folders.first(where: { $0.kind == .inbox && $0.accountID == messages[i].accountID }) {
                    messages[i].folderID = inbox.id
                }
            }
        }
    }

    func reorderAccounts(_ ids: [UUID]) {
        for (idx, id) in ids.enumerated() {
            if let i = accounts.firstIndex(where: { $0.id == id }) {
                accounts[i].sortOrder = idx
            }
        }
        accounts.sort { $0.sortOrder < $1.sortOrder }
    }

    func setInboxPinned(accountID: UUID, pinned: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].inboxPinned = pinned
        if let fi = folders.firstIndex(where: { $0.accountID == accountID && $0.kind == .inbox }) {
            folders[fi].isPinned = pinned
        }
    }

    func setIncludeInUnifiedInbox(accountID: UUID, include: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].includeInUnifiedInbox = include
    }

    func updateSignature(accountID: UUID, signature: String) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].signature = signature
    }

    func updateAccountTint(accountID: UUID, hex: String) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].tintHex = hex
    }

    func upsertFlag(_ flag: MailFlag) {
        if let i = flags.firstIndex(where: { $0.id == flag.id }) {
            flags[i] = flag
        } else {
            flags.append(flag)
        }
    }

    func deleteFlag(_ id: UUID) {
        flags.removeAll { $0.id == id }
        for i in messages.indices where messages[i].flagID == id {
            messages[i].flagID = nil
            messages[i].isFlagged = false
        }
    }

    func sendCompose(_ draft: ComposeDraft) {
        let sentFolder = folders.first { $0.kind == .sent && $0.accountID == draft.accountID }
        let folderID = sentFolder?.id ?? folders.first { $0.kind == .sent }?.id ?? UUID()
        let account = account(for: draft.accountID)
        let bodyWithSig: String
        if let sig = account?.signature, !sig.isEmpty {
            bodyWithSig = draft.body + "\n\n--\n" + sig
        } else {
            bodyWithSig = draft.body
        }
        let msg = MailMessage(
            accountID: draft.accountID,
            folderID: folderID,
            fromName: account?.name ?? "Me",
            fromAddress: draft.fromAddress,
            toAddresses: draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            ccAddresses: draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            subject: draft.subject,
            snippet: String(bodyWithSig.prefix(120)),
            body: bodyWithSig,
            receivedAt: .now,
            isRead: true,
            deliveredTo: draft.fromAddress,
            disposition: .normal,
            isDraft: false
        )
        messages.insert(msg, at: 0)
    }

    func saveApproveDraft(_ draft: ComposeDraft, messageID: UUID?) {
        let approveID = folders.first { $0.kind == .approve }?.id ?? approveFolderID
        if let messageID, let i = messages.firstIndex(where: { $0.id == messageID }) {
            messages[i].subject = draft.subject
            messages[i].body = draft.body
            messages[i].snippet = String(draft.body.prefix(120))
            messages[i].toAddresses = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            messages[i].ccAddresses = draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            messages[i].disposition = .pendingApproval
            messages[i].folderID = approveID
            messages[i].isDraft = true
        } else {
            let account = accounts.first { $0.isCalliope } ?? accounts.first!
            let msg = MailMessage(
                accountID: account.id,
                folderID: approveID,
                fromName: "Calliope",
                fromAddress: account.email,
                toAddresses: draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                ccAddresses: draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                subject: draft.subject,
                snippet: String(draft.body.prefix(120)),
                body: draft.body,
                isRead: true,
                deliveredTo: account.email,
                disposition: .pendingApproval,
                isDraft: true
            )
            messages.insert(msg, at: 0)
        }
    }

    func approveAndSend(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let draft = ComposeDraft(
            mode: .editDraft(messages[i]),
            fromAddress: messages[i].fromAddress,
            to: messages[i].toAddresses.joined(separator: ", "),
            cc: messages[i].ccAddresses.joined(separator: ", "),
            subject: messages[i].subject,
            body: messages[i].body,
            accountID: messages[i].accountID
        )
        messages.remove(at: i)
        sendCompose(draft)
    }

    func rejectApprove(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].disposition = .rejected
        deleteRecessed(messageID)
    }

    func removeMessage(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    func suggestSmartFile(for message: MailMessage) -> MailFolder? {
        // Stub: prefer a custom folder whose name appears in subject, else first custom.
        let customs = folders.filter { $0.kind == .custom && $0.accountID == message.accountID }
        if let hit = customs.first(where: { message.subject.localizedCaseInsensitiveContains($0.name) }) {
            return hit
        }
        return customs.first
    }

    // MARK: - Seed

    private func seed() {
        let workID = UUID()
        let personalID = UUID()
        let calliopeID = UUID()

        accounts = [
            MailAccount(
                id: workID,
                name: "Kale Yeah Work",
                email: "derek@kaleyeah.example",
                tintHex: "1F8A5B",
                signature: "Derek Brown\nKale Yeah!\nOrganic certification & ops",
                includeInUnifiedInbox: true,
                isCalliope: false,
                sortOrder: 0,
                inboxPinned: true
            ),
            MailAccount(
                id: personalID,
                name: "Personal",
                email: "derek.personal@example.com",
                tintHex: "5B7C99",
                signature: "— Derek",
                includeInUnifiedInbox: true,
                isCalliope: false,
                sortOrder: 1,
                inboxPinned: true
            ),
            MailAccount(
                id: calliopeID,
                name: "Calliope",
                email: "calliope@kaleyeah.example",
                tintHex: "C47A2C",
                signature: "Calliope · drafting assistant for Kale Yeah!",
                includeInUnifiedInbox: false,
                isCalliope: true,
                sortOrder: 2,
                inboxPinned: false
            ),
        ]

        flags = MailFlag.defaults
        lastUsedFlagID = flags.first?.id

        var folderList: [MailFolder] = [
            MailFolder(id: approveFolderID, accountID: calliopeID, name: "Approve", kind: .approve, sortOrder: -2, isPinned: true, isSmart: true),
            MailFolder(id: snoozedFolderID, accountID: nil, name: "Snoozed", kind: .snoozed, sortOrder: -1, isPinned: true, isSmart: true),
            MailFolder(id: junkFolderID, accountID: nil, name: "Junk", kind: .junk, sortOrder: 90, isPinned: false, isSmart: true),
        ]

        for account in accounts {
            let base = account.sortOrder * 10
            let inbox = MailFolder(accountID: account.id, name: "Inbox", kind: .inbox, sortOrder: base, isPinned: account.inboxPinned)
            let sent = MailFolder(accountID: account.id, name: "Sent", kind: .sent, sortOrder: base + 1)
            let drafts = MailFolder(accountID: account.id, name: "Drafts", kind: .drafts, sortOrder: base + 2)
            let archive = MailFolder(accountID: account.id, name: "Archive", kind: .archive, sortOrder: base + 3)
            let trash = MailFolder(accountID: account.id, name: "Trash", kind: .trash, sortOrder: base + 4)
            folderList.append(contentsOf: [inbox, sent, drafts, archive, trash])
            if account.id == workID {
                folderList.append(MailFolder(accountID: workID, name: "Inspections", kind: .custom, sortOrder: base + 5))
                folderList.append(MailFolder(accountID: workID, name: "Vendors", kind: .custom, sortOrder: base + 6))
            }
        }
        folders = folderList

        func inboxID(_ account: UUID) -> UUID {
            folders.first { $0.accountID == account && $0.kind == .inbox }!.id
        }
        func customID(_ name: String) -> UUID {
            folders.first { $0.name == name && $0.kind == .custom }!.id
        }

        let cal = Calendar.current
        func hoursAgo(_ h: Int) -> Date { cal.date(byAdding: .hour, value: -h, to: Date())! }
        func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: Date())! }

        messages = [
            MailMessage(
                accountID: workID,
                folderID: inboxID(workID),
                fromName: "Maya Chen",
                fromAddress: "maya@starfine.example",
                toAddresses: ["derek@kaleyeah.example"],
                subject: "Inspection window for PR-3418",
                snippet: "Can we lock Tuesday morning for the organic walkthrough? Packing line is quieter then.",
                body: """
                Hi Derek,

                Can we lock Tuesday morning for the organic walkthrough? Packing line is quieter then.

                I’ll have the lot codes ready.

                Thanks,
                Maya
                """,
                receivedAt: hoursAgo(2),
                isRead: false,
                attachments: [
                    MailAttachment(filename: "lot-codes.pdf", mimeType: "application/pdf", byteSize: 84211, demoPayloadHint: "pdf"),
                    MailAttachment(filename: "tracker.exe", mimeType: "application/octet-stream", byteSize: 204800, demoPayloadHint: "blocked"),
                ],
                deliveredTo: "derek@kaleyeah.example"
            ),
            MailMessage(
                accountID: workID,
                folderID: inboxID(workID),
                fromName: "Ops Desk",
                fromAddress: "ops@kaleyeah.example",
                toAddresses: ["derek@kaleyeah.example"],
                ccAddresses: ["team@kaleyeah.example"],
                subject: "Cold storage humidity nudge",
                snippet: "Humidity drifted above target overnight. Chart attached — nothing alarming yet.",
                body: "Humidity drifted above target overnight. Chart attached — nothing alarming yet.\n\nPlease glance when you can.",
                receivedAt: hoursAgo(5),
                isRead: true,
                isFlagged: true,
                flagID: flags[0].id,
                attachments: [
                    MailAttachment(filename: "humidity.png", mimeType: "image/png", byteSize: 120_400, demoPayloadHint: "image"),
                ],
                deliveredTo: "derek@kaleyeah.example"
            ),
            MailMessage(
                accountID: workID,
                folderID: customID("Vendors"),
                fromName: "JSS Almonds",
                fromAddress: "billing@jss.example",
                toAddresses: ["derek@kaleyeah.example"],
                subject: "PO confirmation Pr2663",
                snippet: "Confirming receipt of PO Pr2663. Ship date still looks good for next week.",
                body: "Confirming receipt of PO Pr2663. Ship date still looks good for next week.",
                receivedAt: daysAgo(1),
                isRead: true,
                deliveredTo: "derek@kaleyeah.example"
            ),
            MailMessage(
                accountID: personalID,
                folderID: inboxID(personalID),
                fromName: "Library Holds",
                fromAddress: "holds@citylibrary.example",
                toAddresses: ["derek.personal@example.com"],
                subject: "Your hold is ready: Leaf & Ledger",
                snippet: "A cheerful reminder — your hold is waiting at the front desk through Friday.",
                body: "A cheerful reminder — your hold is waiting at the front desk through Friday.\n\nHappy reading!",
                receivedAt: hoursAgo(8),
                isRead: false,
                deliveredTo: "derek.personal@example.com"
            ),
            MailMessage(
                accountID: personalID,
                folderID: inboxID(personalID),
                fromName: "Sam Rivera",
                fromAddress: "sam@friends.example",
                toAddresses: ["derek.personal@example.com"],
                subject: "Sunday hike?",
                snippet: "Weather looks kind. Want to do the short ridge loop after brunch?",
                body: "Weather looks kind. Want to do the short ridge loop after brunch?",
                receivedAt: daysAgo(2),
                isRead: true,
                deliveredTo: "derek.personal@example.com"
            ),
            MailMessage(
                accountID: calliopeID,
                folderID: approveFolderID,
                fromName: "Calliope",
                fromAddress: "calliope@kaleyeah.example",
                toAddresses: ["maya@starfine.example"],
                subject: "Re: Inspection window for PR-3418",
                snippet: "Draft: Thanks Maya — Tuesday 9:30 works on our side. We’ll bring checklists…",
                body: """
                Hi Maya,

                Thanks — Tuesday 9:30 works on our side. We’ll bring the Stage 1 checklists and a spare tablet.

                See you then,
                Derek
                """,
                receivedAt: hoursAgo(1),
                isRead: true,
                deliveredTo: "calliope@kaleyeah.example",
                disposition: .pendingApproval,
                isDraft: true
            ),
            MailMessage(
                accountID: calliopeID,
                folderID: approveFolderID,
                fromName: "Calliope",
                fromAddress: "calliope@kaleyeah.example",
                toAddresses: ["billing@jss.example"],
                subject: "Re: PO confirmation Pr2663",
                snippet: "Draft: Noted — please hold the lot until we confirm cold-chain slots…",
                body: "Hi,\n\nNoted — please hold the lot until we confirm cold-chain slots tomorrow morning.\n\nThanks,\nDerek",
                receivedAt: hoursAgo(3),
                isRead: true,
                deliveredTo: "calliope@kaleyeah.example",
                disposition: .pendingApproval,
                isDraft: true
            ),
            MailMessage(
                accountID: workID,
                folderID: inboxID(workID),
                fromName: "Newsletter Sprout",
                fromAddress: "hello@sproutweekly.example",
                toAddresses: ["derek@kaleyeah.example"],
                subject: "Five tiny harvest tips",
                snippet: "This week: leaf wash order, clipboard cheer, and a kinder way to label bins.",
                body: "This week: leaf wash order, clipboard cheer, and a kinder way to label bins.",
                receivedAt: daysAgo(3),
                isRead: true,
                deliveredTo: "derek@kaleyeah.example"
            ),
            MailMessage(
                accountID: workID,
                folderID: junkFolderID,
                fromName: "Prize Bot",
                fromAddress: "win@not-real.example",
                toAddresses: ["derek@kaleyeah.example"],
                subject: "You won a yacht (no)",
                snippet: "Obviously junk. Train me later.",
                body: "Obviously junk. Train me later.",
                receivedAt: daysAgo(4),
                isRead: true,
                attachments: [
                    MailAttachment(filename: "click-me.js", mimeType: "text/javascript", byteSize: 1200, demoPayloadHint: "blocked"),
                    MailAttachment(filename: "offer.html", mimeType: "text/html", byteSize: 4400, demoPayloadHint: "blocked"),
                ],
                deliveredTo: "derek@kaleyeah.example"
            ),
        ]
    }
}
