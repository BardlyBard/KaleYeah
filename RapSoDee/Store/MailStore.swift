import Foundation

/// Abstraction for future IMAP / Exchange / Microsoft Graph backends.
protocol MailStore: AnyObject {
    var accounts: [MailAccount] { get }
    var folders: [MailFolder] { get }
    var messages: [MailMessage] { get }
    var flags: [MailFlag] { get }
    var sort: MessageSort { get set }
    var filter: MessageFilter { get set }
    var searchText: String { get set }

    func messages(for selection: LadderSelection) -> [MailMessage]
    func account(for id: UUID) -> MailAccount?
    func folder(for id: UUID) -> MailFolder?

    func markRead(_ id: UUID, read: Bool)
    func toggleFlag(_ id: UUID, flagID: UUID?)
    func archive(_ id: UUID)
    func deleteRecessed(_ id: UUID)
    func file(_ id: UUID, into folderID: UUID)
    func snooze(_ id: UUID, until: Date)
    func unsnoozeDue()

    func reorderAccounts(_ ids: [UUID])
    func setInboxPinned(accountID: UUID, pinned: Bool)
    func setIncludeInUnifiedInbox(accountID: UUID, include: Bool)
    func updateSignature(accountID: UUID, signature: String)
    func updateAccountTint(accountID: UUID, hex: String)

    func upsertFlag(_ flag: MailFlag)
    func deleteFlag(_ id: UUID)

    func sendCompose(_ draft: ComposeDraft)
    func saveApproveDraft(_ draft: ComposeDraft, messageID: UUID?)
    func approveAndSend(_ messageID: UUID)
    func rejectApprove(_ messageID: UUID)

    func removeMessage(_ id: UUID)
    func suggestSmartFile(for message: MailMessage) -> MailFolder?
}
