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
    /// Stage-1 notification stub — focusAware / vipOnly / mute
    var notificationPolicyRaw: String = "focusAware"
    /// Soft muse chime when new mail arrives (default on).
    var playSoundForNewMail: Bool = true

    // MARK: Gmail live account
    var gmailSyncStatus: String = ""
    var gmailIsSyncing: Bool = false
    var gmailNeedsSetup: Bool = true
    var gmailLastError: String?

    // MARK: Microsoft 365 live account
    var office365SyncStatus: String = ""
    var office365IsSyncing: Bool = false
    var office365NeedsSetup: Bool = true
    var office365LastError: String?

    private let archiveFolderID = UUID()
    private let trashFolderID = UUID()
    private let snoozedFolderID = UUID()
    private let approveFolderID = UUID()
    private let junkFolderID = UUID()

    init() {
        seed()
        restoreGmailAccountShellIfNeeded()
        restoreOffice365AccountShellIfNeeded()
        gmailNeedsSetup = !GmailSyncService.hasKeychainCredentials(email: gmailAccount()?.email)
        office365NeedsSetup = MSALAppConfig.rememberedSignedInEmail == nil
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

    func renameFlag(id: UUID, name: String) {
        guard let i = flags.firstIndex(where: { $0.id == id }) else { return }
        flags[i].name = name
    }

    func updateFlagColor(id: UUID, colorHex: String) {
        guard let i = flags.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = colorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard cleaned.count == 6 || cleaned.count == 8 else { return }
        flags[i].colorHex = cleaned
    }

    func deleteFlag(_ id: UUID) {
        flags.removeAll { $0.id == id }
        for i in messages.indices where messages[i].flagID == id {
            messages[i].flagID = nil
            messages[i].isFlagged = false
        }
    }

    /// Demo / Stage-1: insert an incoming message and apply notification policy (sound).
    @discardableResult
    func simulateNewMail() -> MailMessage {
        let work = accounts.first { !$0.isCalliope } ?? accounts[0]
        let inbox = folders.first { $0.kind == .inbox && $0.accountID == work.id }
            ?? folders.first { $0.kind == .inbox }
        let folderID = inbox?.id ?? UUID()
        let subjects = [
            ("Leaf Dispatch", "A soft ping from the packing floor — clipboard check when you can."),
            ("Muse note", "Tiny reminder: the ridge loop still looks friendly this evening."),
            ("Cold-chain chirp", "Humidity settled. No action needed — just a cheerful heads-up."),
        ]
        let pick = subjects.randomElement()!
        let msg = MailMessage(
            accountID: work.id,
            folderID: folderID,
            fromName: "RapSoDee Demo",
            fromAddress: "demo@rapsodee.example",
            toAddresses: [work.email],
            subject: pick.0,
            snippet: pick.1,
            body: pick.1 + "\n\n— simulated new mail for Stage 1",
            receivedAt: .now,
            isRead: false,
            deliveredTo: work.email
        )
        ingestIncoming(msg)
        return msg
    }

    /// Insert an incoming message at the top and fire notification policy.
    func ingestIncoming(_ message: MailMessage) {
        messages.insert(message, at: 0)
        applyNotificationPolicy(for: message)
    }

    /// NotificationPolicy stub: mute skips; vipOnly is reserved; otherwise play sound if enabled.
    func applyNotificationPolicy(for message: MailMessage) {
        switch notificationPolicyRaw {
        case "mute":
            return
        case "vipOnly":
            // VIP routing arrives later — Stage 1 treats simulate as audible when sound is on.
            break
        default:
            break // focusAware
        }
        guard playSoundForNewMail else { return }
        // Skip outbound/draft dispositions for safety if callers reuse ingest later.
        if message.disposition == .pendingApproval { return }
        MuseNewMailSound.play()
    }

    func sendCompose(_ draft: ComposeDraft) {
        if let account = account(for: draft.accountID), account.isLiveGmail {
            Task { @MainActor in await sendGmailCompose(draft) }
            return
        }
        if let account = account(for: draft.accountID), account.isLiveOffice365 {
            Task { @MainActor in await sendOffice365Compose(draft) }
            return
        }
        insertLocalSent(draft)
    }

    private func insertLocalSent(_ draft: ComposeDraft) {
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


    // MARK: - Live Gmail

    func gmailAccount() -> MailAccount? {
        accounts.first { $0.isLiveGmail }
    }

    /// Ensure a Gmail account card exists when we have a remembered email (even before password).
    func restoreGmailAccountShellIfNeeded() {
        if gmailAccount() != nil { return }
        let email = GmailSyncService.storedEmail() ?? GmailDefaults.defaultEmail
        let id = GmailSyncService.storedAccountID() ?? UUID()
        // Only materialize the live account if Keychain has creds OR user previously saved the email.
        let hasCreds = KeychainCredentialStore.hasCredentials(forEmail: email)
        let remembered = GmailSyncService.storedEmail() != nil
        guard hasCreds || remembered else { return }
        ensureGmailAccount(email: email, id: id)
    }

    @discardableResult
    func ensureGmailAccount(email: String, id: UUID = UUID()) -> MailAccount {
        if let existing = gmailAccount() {
            if let i = accounts.firstIndex(where: { $0.id == existing.id }) {
                accounts[i].email = email
                accounts[i].name = "Gmail"
            }
            GmailSyncService.rememberAccount(email: email, id: existing.id)
            return accounts.first { $0.isLiveGmail }!
        }
        let account = MailAccount(
            id: id,
            name: "Gmail",
            email: email,
            tintHex: GmailDefaults.tintHex,
            signature: "— Derek",
            includeInUnifiedInbox: true,
            isCalliope: false,
            sortOrder: -1,
            inboxPinned: true,
            isLiveGmail: true
        )
        accounts.insert(account, at: 0)
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        let base = -10
        let inbox = MailFolder(accountID: id, name: "Inbox", kind: .inbox, sortOrder: base, isPinned: true)
        let sent = MailFolder(accountID: id, name: "Sent", kind: .sent, sortOrder: base + 1)
        let drafts = MailFolder(accountID: id, name: "Drafts", kind: .drafts, sortOrder: base + 2)
        let archive = MailFolder(accountID: id, name: "Archive", kind: .archive, sortOrder: base + 3)
        let trash = MailFolder(accountID: id, name: "Trash", kind: .trash, sortOrder: base + 4)
        folders.append(contentsOf: [inbox, sent, drafts, archive, trash])
        GmailSyncService.rememberAccount(email: email, id: id)
        return account
    }

    func removeGmailAccount() {
        guard let account = gmailAccount() else { return }
        KeychainCredentialStore.deletePassword(forEmail: account.email)
        GmailSyncService.clearRememberedAccount()
        messages.removeAll { $0.accountID == account.id }
        folders.removeAll { $0.accountID == account.id }
        accounts.removeAll { $0.id == account.id }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        gmailNeedsSetup = true
        gmailSyncStatus = "Gmail account removed — demo mail still available."
        gmailLastError = nil
    }

    func saveGmailCredentials(email: String, appPassword: String) throws {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !pass.isEmpty else {
            throw MailNetError.unexpected("Email and App Password are required")
        }
        try KeychainCredentialStore.savePassword(pass, forEmail: cleaned)
        _ = ensureGmailAccount(email: cleaned, id: GmailSyncService.storedAccountID() ?? UUID())
        gmailNeedsSetup = false
        gmailSyncStatus = "Credentials saved in Keychain."
        gmailLastError = nil
    }

    /// Test IMAP/SMTP. Prefer an in-field App Password when provided; otherwise use Keychain.
    /// Does not require an existing account card when email + password (field or Keychain) are available.
    func testGmailConnection(email overrideEmail: String? = nil, appPassword overridePassword: String? = nil) async {
        let email = (overrideEmail ?? gmailAccount()?.email ?? GmailSyncService.storedEmail() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            gmailLastError = "Enter a Gmail address"
            return
        }
        let fieldPass = (overridePassword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password: String
        if !fieldPass.isEmpty {
            password = fieldPass
        } else if let stored = KeychainCredentialStore.password(forEmail: email) {
            password = stored
        } else {
            gmailLastError = "Enter an App Password or save credentials first"
            gmailNeedsSetup = true
            return
        }
        gmailIsSyncing = true
        gmailLastError = nil
        gmailSyncStatus = "Testing connection…"
        do {
            try await GmailSyncService.testConnection(email: email, password: password)
            gmailSyncStatus = "Connection OK (IMAP + SMTP)"
        } catch {
            gmailLastError = error.localizedDescription
            gmailSyncStatus = "Connection failed"
        }
        gmailIsSyncing = false
    }

    func syncGmailNow() async {
        guard let account = gmailAccount() else {
            gmailNeedsSetup = true
            gmailSyncStatus = "Add Gmail in Settings → Accounts"
            return
        }
        guard let password = KeychainCredentialStore.password(forEmail: account.email) else {
            gmailNeedsSetup = true
            gmailSyncStatus = "Paste a Gmail App Password in Settings"
            return
        }
        guard let folderIDs = liveFolderIDs(for: account.id) else {
            gmailLastError = "Gmail folders missing"
            return
        }
        gmailIsSyncing = true
        gmailLastError = nil
        gmailSyncStatus = "Syncing Gmail…"
        let previousIDs = Set(messages.filter { $0.accountID == account.id }.map(\.id))
        do {
            let (fetched, _, result) = try await GmailSyncService.sync(
                email: account.email,
                password: password,
                accountID: account.id,
                folderIDs: folderIDs
            )
            // Replace live messages for this account; keep local flags if same id.
            var flagMemory: [UUID: (Bool, UUID?)] = [:]
            for m in messages where m.accountID == account.id {
                flagMemory[m.id] = (m.isFlagged, m.flagID)
            }
            messages.removeAll { $0.accountID == account.id }
            var newOnes: [MailMessage] = []
            for var msg in fetched {
                if let mem = flagMemory[msg.id], mem.0 {
                    msg.isFlagged = true
                    msg.flagID = mem.1
                }
                if !previousIDs.contains(msg.id) && !msg.isRead {
                    newOnes.append(msg)
                }
                messages.append(msg)
            }
            messages.sort { $0.receivedAt > $1.receivedAt }
            gmailSyncStatus = result.status
            gmailNeedsSetup = false
            for msg in newOnes.prefix(3) {
                applyNotificationPolicy(for: msg)
            }
        } catch {
            gmailLastError = error.localizedDescription
            gmailSyncStatus = "Sync failed"
        }
        gmailIsSyncing = false
    }

    func bootstrapGmailOnLaunch() async {
        await bootstrapLiveAccountsOnLaunch()
    }

    func bootstrapLiveAccountsOnLaunch() async {
        restoreGmailAccountShellIfNeeded()
        restoreOffice365AccountShellIfNeeded()
        if let account = gmailAccount(), KeychainCredentialStore.hasCredentials(forEmail: account.email) {
            gmailNeedsSetup = false
            await syncGmailNow()
        } else {
            gmailNeedsSetup = true
            if gmailSyncStatus.isEmpty {
                gmailSyncStatus = "Demo accounts ready. Add Gmail App Password in Settings → Accounts."
            }
        }
        await MSALAuthService.shared.refreshSignedInStateFromCache()
        let msalSignedIn = await MainActor.run { MSALAuthService.shared.isSignedIn }
        if msalSignedIn || MSALAppConfig.rememberedSignedInEmail != nil {
            restoreOffice365AccountShellIfNeeded()
            office365NeedsSetup = false
            await syncOffice365Now()
        } else {
            office365NeedsSetup = true
            if office365SyncStatus.isEmpty {
                office365SyncStatus = "Optional: Sign in with Microsoft in Settings → Microsoft 365."
            }
        }
    }

    private func liveFolderIDs(for accountID: UUID) -> IMAPFolderIDs? {
        guard
            let inbox = folders.first(where: { $0.accountID == accountID && $0.kind == .inbox })?.id,
            let sent = folders.first(where: { $0.accountID == accountID && $0.kind == .sent })?.id,
            let drafts = folders.first(where: { $0.accountID == accountID && $0.kind == .drafts })?.id,
            let archive = folders.first(where: { $0.accountID == accountID && $0.kind == .archive })?.id,
            let trash = folders.first(where: { $0.accountID == accountID && $0.kind == .trash })?.id
        else { return nil }
        return IMAPFolderIDs(inbox: inbox, sent: sent, drafts: drafts, archive: archive, trash: trash)
    }

    private func sendGmailCompose(_ draft: ComposeDraft) async {
        guard let account = account(for: draft.accountID), account.isLiveGmail else {
            insertLocalSent(draft)
            return
        }
        guard let password = KeychainCredentialStore.password(forEmail: account.email) else {
            gmailLastError = "Missing App Password — open Settings → Accounts"
            gmailNeedsSetup = true
            return
        }
        gmailIsSyncing = true
        gmailSyncStatus = "Sending…"
        do {
            try await GmailSyncService.send(
                email: account.email,
                password: password,
                draft: draft,
                signature: account.signature
            )
            insertLocalSent(draft)
            gmailSyncStatus = "Sent via Gmail SMTP"
            gmailLastError = nil
        } catch {
            gmailLastError = error.localizedDescription
            gmailSyncStatus = "Send failed"
        }
        gmailIsSyncing = false
    }


    // MARK: - Live Microsoft 365 (MSAL + Graph)

    func office365Account() -> MailAccount? {
        accounts.first { $0.isLiveOffice365 }
    }

    func restoreOffice365AccountShellIfNeeded() {
        if office365Account() != nil { return }
        let email = MSALAppConfig.rememberedSignedInEmail
            ?? Office365SyncService.storedEmail()
            ?? Office365Defaults.defaultEmail
        let id = Office365SyncService.storedAccountID() ?? UUID()
        let signedIn = MSALAppConfig.rememberedSignedInEmail != nil
        let remembered = Office365SyncService.storedEmail() != nil
        guard signedIn || remembered else { return }
        ensureOffice365Account(email: email, id: id)
    }

    @discardableResult
    func ensureOffice365Account(email: String, id: UUID = UUID()) -> MailAccount {
        if let existing = office365Account() {
            if let i = accounts.firstIndex(where: { $0.id == existing.id }) {
                accounts[i].email = email
                accounts[i].name = "Microsoft 365"
                accounts[i].tintHex = accounts[i].tintHex.isEmpty ? Office365Defaults.tintHex : accounts[i].tintHex
            }
            Office365SyncService.rememberAccount(email: email, id: existing.id)
            return accounts.first { $0.isLiveOffice365 }!
        }
        let account = MailAccount(
            id: id,
            name: "Microsoft 365",
            email: email,
            tintHex: Office365Defaults.tintHex,
            signature: "Derek Brown\nKale Yeah Inspections",
            includeInUnifiedInbox: true,
            isCalliope: false,
            sortOrder: -1,
            inboxPinned: true,
            isLiveGmail: false,
            isLiveOffice365: true
        )
        if let gmailIdx = accounts.firstIndex(where: { $0.isLiveGmail }) {
            accounts.insert(account, at: gmailIdx + 1)
        } else {
            accounts.insert(account, at: 0)
        }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        let base = -20
        let inbox = MailFolder(accountID: id, name: "Inbox", kind: .inbox, sortOrder: base, isPinned: true)
        let sent = MailFolder(accountID: id, name: "Sent", kind: .sent, sortOrder: base + 1)
        let drafts = MailFolder(accountID: id, name: "Drafts", kind: .drafts, sortOrder: base + 2)
        let archive = MailFolder(accountID: id, name: "Archive", kind: .archive, sortOrder: base + 3)
        let trash = MailFolder(accountID: id, name: "Trash", kind: .trash, sortOrder: base + 4)
        folders.append(contentsOf: [inbox, sent, drafts, archive, trash])
        Office365SyncService.rememberAccount(email: email, id: id)
        return account
    }

    func removeOffice365Account() {
        guard let account = office365Account() else {
            Task { @MainActor in await MSALAuthService.shared.signOut() }
            office365NeedsSetup = true
            return
        }
        KeychainCredentialStore.deletePassword(forEmail: account.email)
        Office365SyncService.clearRememberedAccount()
        messages.removeAll { $0.accountID == account.id }
        folders.removeAll { $0.accountID == account.id }
        accounts.removeAll { $0.id == account.id }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        Task { @MainActor in await MSALAuthService.shared.signOut() }
        office365NeedsSetup = true
        office365SyncStatus = "Signed out of Microsoft 365 — Gmail and demo mail still available."
        office365LastError = nil
    }

    /// Interactive MSAL sign-in, then Graph sync.
    func signInMicrosoft365(clientIDOverride: String? = nil) async {
        if let override = clientIDOverride {
            MSALAppConfig.setClientIDOverride(override)
        }
        guard !MSALAppConfig.clientID.isEmpty else {
            office365LastError = MSALAuthError.missingClientID.localizedDescription
            office365NeedsSetup = true
            return
        }
        office365IsSyncing = true
        office365LastError = nil
        office365SyncStatus = "Signing in with Microsoft…"
        do {
            _ = try await MSALAuthService.shared.signIn(loginHint: Office365Defaults.defaultEmail)
            let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            _ = ensureOffice365Account(email: email, id: Office365SyncService.storedAccountID() ?? UUID())
            office365NeedsSetup = false
            office365SyncStatus = "Signed in as \(email)"
            office365IsSyncing = false
            await syncOffice365Now()
        } catch {
            office365LastError = error.localizedDescription
            office365SyncStatus = "Sign-in failed"
            office365IsSyncing = false
        }
    }

    func signOutMicrosoft365() async {
        office365IsSyncing = true
        office365SyncStatus = "Signing out…"
        await MSALAuthService.shared.signOut()
        if let account = office365Account() {
            KeychainCredentialStore.deletePassword(forEmail: account.email)
            messages.removeAll { $0.accountID == account.id }
            folders.removeAll { $0.accountID == account.id }
            accounts.removeAll { $0.id == account.id }
            for (idx, _) in accounts.enumerated() {
                accounts[idx].sortOrder = idx
            }
        }
        Office365SyncService.clearRememberedAccount()
        office365NeedsSetup = true
        office365SyncStatus = "Signed out of Microsoft 365."
        office365LastError = nil
        office365IsSyncing = false
    }

    func syncOffice365Now() async {
        restoreOffice365AccountShellIfNeeded()
        if office365Account() == nil {
            do {
                let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
                let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                _ = ensureOffice365Account(email: email)
            } catch {
                office365NeedsSetup = true
                office365SyncStatus = "Sign in with Microsoft in Settings → Microsoft 365"
                return
            }
        }
        guard let account = office365Account() else {
            office365NeedsSetup = true
            office365SyncStatus = "Sign in with Microsoft in Settings → Microsoft 365"
            return
        }
        guard let folderIDs = liveFolderIDs(for: account.id) else {
            office365LastError = "Microsoft 365 folders missing"
            return
        }
        office365IsSyncing = true
        office365LastError = nil
        office365SyncStatus = "Syncing Microsoft 365 via Graph…"
        let previousIDs = Set(messages.filter { $0.accountID == account.id }.map(\.id))
        do {
            let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: true, loginHint: account.email)
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            if email.lowercased() != account.email.lowercased() {
                _ = ensureOffice365Account(email: email, id: account.id)
            }
            let (fetched, result) = try await MicrosoftGraphMailService.sync(
                accessToken: token,
                accountID: account.id,
                folderIDs: folderIDs,
                accountEmail: email
            )
            var flagMemory: [UUID: (Bool, UUID?)] = [:]
            for m in messages where m.accountID == account.id {
                flagMemory[m.id] = (m.isFlagged, m.flagID)
            }
            messages.removeAll { $0.accountID == account.id }
            var newOnes: [MailMessage] = []
            for var msg in fetched {
                if let mem = flagMemory[msg.id], mem.0 {
                    msg.isFlagged = true
                    msg.flagID = mem.1
                }
                if !previousIDs.contains(msg.id) && !msg.isRead {
                    newOnes.append(msg)
                }
                messages.append(msg)
            }
            messages.sort { $0.receivedAt > $1.receivedAt }
            office365SyncStatus = result.status
            office365NeedsSetup = false
            for msg in newOnes.prefix(3) {
                applyNotificationPolicy(for: msg)
            }
        } catch {
            office365LastError = error.localizedDescription
            office365SyncStatus = "Sync failed"
            if error.localizedDescription.lowercased().contains("not signed")
                || error.localizedDescription.lowercased().contains("client id") {
                office365NeedsSetup = true
            }
        }
        office365IsSyncing = false
    }

    private func sendOffice365Compose(_ draft: ComposeDraft) async {
        guard let account = account(for: draft.accountID), account.isLiveOffice365 else {
            insertLocalSent(draft)
            return
        }
        office365IsSyncing = true
        office365SyncStatus = "Sending…"
        do {
            let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: true, loginHint: account.email)
            try await MicrosoftGraphMailService.sendMail(
                accessToken: token,
                draft: draft,
                fromEmail: draft.fromAddress.isEmpty ? account.email : draft.fromAddress,
                signature: account.signature
            )
            insertLocalSent(draft)
            office365SyncStatus = "Sent via Microsoft Graph"
            office365LastError = nil
        } catch {
            office365LastError = error.localizedDescription
            office365SyncStatus = "Send failed"
        }
        office365IsSyncing = false
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
