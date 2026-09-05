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
    /// When the current M365 busy operation started (for Settings escape hatch).
    var office365SyncStartedAt: Date?
    var office365NeedsSetup: Bool = true
    var office365LastError: String?
    /// Overall Graph sync budget (token + inbox + sent + attachments).
    private static let office365SyncTimeoutSeconds: TimeInterval = 90

    /// Universal toolbar sync busy (Gmail + M365).
    var isUniversalSyncing: Bool = false
    /// Prevent overlapping Sync all / auto-sync runs.
    private var syncAllInFlight: Bool = false

    var isAnyLiveSyncing: Bool {
        isUniversalSyncing || gmailIsSyncing || office365IsSyncing
    }

    private let archiveFolderID = UUID()
    private let trashFolderID = UUID()
    private let snoozedFolderID = UUID()
    private let approveFolderID = UUID()
    private let junkFolderID = UUID()

    init() {
        seed()
        // Prior crash/hang must never leave Sign in / Sync / Sign out permanently grayed out.
        office365IsSyncing = false
        office365SyncStartedAt = nil
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

    func renameAccount(accountID: UUID, name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accounts[i].name = trimmed
        MailDisplayNames.setAccountName(trimmed, for: accountID)
    }

    func renameFolder(folderID: UUID, name: String) {
        guard let i = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[i].name = trimmed
        MailDisplayNames.setFolderName(trimmed, for: folderID)
    }

    func displayName(for folder: MailFolder) -> String {
        MailDisplayNames.folderName(for: folder.id) ?? folder.name
    }

    private func applyPersistedDisplayNames() {
        for i in accounts.indices {
            if let override = MailDisplayNames.accountName(for: accounts[i].id) {
                accounts[i].name = override
            }
        }
        for i in folders.indices {
            if let override = MailDisplayNames.folderName(for: folders[i].id) {
                folders[i].name = override
            }
        }
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
        let attachments = draft.attachments.map {
            MailAttachment(
                id: $0.id,
                filename: $0.filename,
                mimeType: $0.mimeType,
                byteSize: $0.byteSize,
                localPath: $0.localPath
            )
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
            attachments: attachments,
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
            guard let account = accounts.first(where: { !$0.isCalliope }) ?? accounts.first else { return }
            let msg = MailMessage(
                accountID: account.id,
                folderID: approveID,
                fromName: account.name,
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
                if let override = MailDisplayNames.accountName(for: existing.id) {
                    accounts[i].name = override
                } else if accounts[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accounts[i].name = "Gmail"
                }
            }
            ensureStandardMailFolders(for: existing.id, baseSort: -10)
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
        applyPersistedDisplayNames()
        return accounts.first { $0.id == id } ?? account
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
        gmailSyncStatus = "Gmail account removed."
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
        if gmailIsSyncing { return }
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
            let synced = Set([folderIDs.inbox, folderIDs.sent, folderIDs.drafts])
            let newOnes = upsertSyncedMessages(
                accountID: account.id,
                syncedFolderIDs: synced,
                fetched: fetched,
                previousIDs: previousIDs
            )
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

    /// Sync every connected live account. Skips if a sync is already running.
    func syncAllConnectedAccounts() async {
        if syncAllInFlight || gmailIsSyncing || office365IsSyncing { return }
        let hasGmail = gmailAccount().map { KeychainCredentialStore.hasCredentials(forEmail: $0.email) } ?? false
        await MSALAuthService.shared.refreshSignedInStateFromCache()
        let msalSignedIn = await MainActor.run { MSALAuthService.shared.isSignedIn }
        let hasOffice = msalSignedIn || MSALAppConfig.rememberedSignedInEmail != nil || office365Account() != nil
        guard hasGmail || hasOffice else { return }

        syncAllInFlight = true
        isUniversalSyncing = true
        defer {
            syncAllInFlight = false
            isUniversalSyncing = false
        }
        if hasGmail {
            await syncGmailNow()
        }
        if hasOffice {
            await syncOffice365Now()
        }
    }

    func bootstrapLiveAccountsOnLaunch() async {
        office365IsSyncing = false
        office365SyncStartedAt = nil
        deduplicateMessagesByRemoteID()
        restoreGmailAccountShellIfNeeded()
        restoreOffice365AccountShellIfNeeded()
        applyPersistedDisplayNames()
        if let account = gmailAccount(), KeychainCredentialStore.hasCredentials(forEmail: account.email) {
            gmailNeedsSetup = false
            await syncGmailNow()
        } else {
            gmailNeedsSetup = true
            if gmailSyncStatus.isEmpty {
                gmailSyncStatus = "Add Gmail App Password in Settings → Accounts."
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

        // Accounts exist but inbox still empty (failed/empty Graph pass) — try once more
        // so launch never leaves Kale Yeah permanently blank without attempting sync.
        if !accounts.isEmpty && messages.isEmpty && !office365NeedsSetup {
            await syncOffice365Now()
        } else if !accounts.isEmpty && messages.isEmpty && !gmailNeedsSetup {
            await syncGmailNow()
        }
    }

    /// Recreate Inbox/Sent/Drafts/Archive/Trash if an account shell lost its folders
    /// (e.g. after demo seed removal left selection pointing at dead IDs).
    private func ensureStandardMailFolders(for accountID: UUID, baseSort: Int) {
        let kinds: [(FolderKind, String, Int, Bool)] = [
            (.inbox, "Inbox", baseSort, true),
            (.sent, "Sent", baseSort + 1, false),
            (.drafts, "Drafts", baseSort + 2, false),
            (.archive, "Archive", baseSort + 3, false),
            (.trash, "Trash", baseSort + 4, false),
        ]
        for (kind, name, order, pinned) in kinds {
            if folders.contains(where: { $0.accountID == accountID && $0.kind == kind }) { continue }
            folders.append(
                MailFolder(accountID: accountID, name: name, kind: kind, sortOrder: order, isPinned: pinned)
            )
        }
    }

    /// True when `selection` still resolves to a live folder / account after demo removal.
    func isValidSelection(_ selection: LadderSelection) -> Bool {
        switch selection {
        case .unifiedInbox, .approve:
            return true
        case .accountInbox(let accountID):
            return accounts.contains(where: { $0.id == accountID })
        case .folder(let id):
            return folders.contains(where: { $0.id == id })
        }
    }

    private func liveFolderIDs(for accountID: UUID) -> IMAPFolderIDs? {
        ensureStandardMailFolders(
            for: accountID,
            baseSort: accounts.first(where: { $0.id == accountID })?.isLiveOffice365 == true ? -20 : -10
        )
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
                if let override = MailDisplayNames.accountName(for: existing.id) {
                    accounts[i].name = override
                } else if accounts[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accounts[i].name = "Microsoft 365"
                }
                accounts[i].tintHex = accounts[i].tintHex.isEmpty ? Office365Defaults.tintHex : accounts[i].tintHex
            }
            ensureStandardMailFolders(for: existing.id, baseSort: -20)
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
        applyPersistedDisplayNames()
        return accounts.first { $0.id == id } ?? account
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
        office365SyncStatus = "Signed out of Microsoft 365."
        office365LastError = nil
    }

    /// Interactive MSAL sign-in, then Graph sync.
    func signInMicrosoft365(clientIDOverride: String? = nil, tenantIDOverride: String? = nil) async {
        if let override = clientIDOverride {
            MSALAppConfig.setClientIDOverride(override)
        }
        if let tenant = tenantIDOverride {
            MSALAppConfig.setTenantIDOverride(tenant)
        }
        guard !MSALAppConfig.clientID.isEmpty else {
            office365LastError = MSALAuthError.missingClientID.localizedDescription
            office365NeedsSetup = true
            return
        }
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Signing in with Microsoft…"
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        do {
            _ = try await MSALAuthService.shared.signIn(loginHint: Office365Defaults.defaultEmail)
            let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            _ = ensureOffice365Account(email: email, id: Office365SyncService.storedAccountID() ?? UUID())
            office365NeedsSetup = false
            office365SyncStatus = "Signed in as \(email)"
            // Clear busy before nested sync so syncOffice365Now can set its own defer.
            office365IsSyncing = false
            office365SyncStartedAt = nil
            await syncOffice365Now()
        } catch {
            office365LastError = error.localizedDescription
            office365SyncStatus = "Sign-in failed"
        }
    }

    /// Device-code fallback when browser redirect hangs after Allow.
    func signInMicrosoft365WithDeviceCode(
        clientIDOverride: String? = nil,
        tenantIDOverride: String? = nil,
        onPrompt: @MainActor @escaping (MSALDeviceCodePrompt) -> Void
    ) async {
        if let override = clientIDOverride {
            MSALAppConfig.setClientIDOverride(override)
        }
        if let tenant = tenantIDOverride {
            MSALAppConfig.setTenantIDOverride(tenant)
        }
        guard !MSALAppConfig.clientID.isEmpty else {
            office365LastError = MSALAuthError.missingClientID.localizedDescription
            office365NeedsSetup = true
            return
        }
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Starting device code sign-in…"
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        do {
            _ = try await MSALAuthService.shared.signInWithDeviceCode(
                loginHint: Office365Defaults.defaultEmail,
                onPrompt: onPrompt
            )
            let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            _ = ensureOffice365Account(email: email, id: Office365SyncService.storedAccountID() ?? UUID())
            office365NeedsSetup = false
            office365SyncStatus = "Signed in as \(email) (device code)"
            office365IsSyncing = false
            office365SyncStartedAt = nil
            await syncOffice365Now()
        } catch {
            office365LastError = error.localizedDescription
            office365SyncStatus = "Device code sign-in failed"
        }
    }

    func signOutMicrosoft365() async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365SyncStatus = "Signing out…"
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
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
    }

    /// Escape hatch when Graph/MSAL hangs — unlocks Sign in / Sync / Sign out immediately.
    func cancelOffice365Sync() {
        MSALAuthService.cancelPendingAuth()
        office365IsSyncing = false
        office365SyncStartedAt = nil
        office365SyncStatus = "Sync / sign-in cancelled"
        if office365LastError == nil {
            office365LastError = "Previous Microsoft session was cancelled. Try Sign in with Microsoft again."
        }
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
        if office365IsSyncing { return }
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Syncing Microsoft 365 via Graph…"
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        let previousIDs = Set(messages.filter { $0.accountID == account.id }.map(\.id))
        let accountID = account.id
        let accountEmailHint = account.email
        let timeout = Self.office365SyncTimeoutSeconds
        do {
            struct SyncPayload {
                var email: String
                var messages: [MailMessage]
                var status: String
                var prunableFolderIDs: Set<UUID>
            }
            let payload: SyncPayload = try await withOffice365SyncTimeout(seconds: timeout) {
                let token = try await MSALAuthService.shared.acquireAccessToken(
                    interactiveIfNeeded: true,
                    loginHint: accountEmailHint
                )
                let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                let (fetched, result, prunable) = try await MicrosoftGraphMailService.sync(
                    accessToken: token,
                    accountID: accountID,
                    folderIDs: folderIDs,
                    accountEmail: email
                )
                return SyncPayload(
                    email: email,
                    messages: fetched,
                    status: result.status,
                    prunableFolderIDs: prunable
                )
            }
            if payload.email.lowercased() != accountEmailHint.lowercased() {
                _ = ensureOffice365Account(email: payload.email, id: accountID)
            }
            // Only prune folders Graph actually listed successfully. Never treat a total
            // failure / empty error payload as authority to wipe Kale Yeah mail.
            let newOnes = upsertSyncedMessages(
                accountID: accountID,
                syncedFolderIDs: payload.prunableFolderIDs,
                fetched: payload.messages,
                previousIDs: previousIDs
            )
            office365SyncStatus = payload.status
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
    }

    private func sendOffice365Compose(_ draft: ComposeDraft) async {
        guard let account = account(for: draft.accountID), account.isLiveOffice365 else {
            insertLocalSent(draft)
            return
        }
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        let toPreview = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2).joined(separator: ", ")
        let preferSMTP = MSALAppConfig.preferSMTPSend
        office365SyncStatus = preferSMTP
            ? "Sending via SMTP XOAUTH2 as \(account.email) → \(toPreview)…"
            : "Sending via Graph draft→send as \(account.email) → \(toPreview)…"
        office365LastError = nil
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        do {
            let status: String
            if preferSMTP {
                status = try await sendOffice365ViaSMTP(draft: draft, account: account)
            } else {
                do {
                    let token = try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: true, loginHint: account.email)
                    let fromEmail = draft.fromAddress.isEmpty ? account.email : draft.fromAddress
                    status = try await MicrosoftGraphMailService.sendMail(
                        accessToken: token,
                        draft: draft,
                        fromEmail: fromEmail,
                        mailboxEmail: account.email,
                        signature: account.signature
                    )
                } catch {
                    // Graph API failure → try SMTP OAuth (NDRs are not visible in-app).
                    let graphDetail = error.localizedDescription
                    office365SyncStatus = "Graph send failed — trying SMTP XOAUTH2… (\(String(graphDetail.prefix(120))))"
                    do {
                        status = try await sendOffice365ViaSMTP(draft: draft, account: account)
                    } catch {
                        let smtpDetail = error.localizedDescription
                        office365LastError = "Graph: \(graphDetail)\nSMTP: \(smtpDetail)"
                        let short = smtpDetail.count > 200 ? String(smtpDetail.prefix(197)) + "…" : smtpDetail
                        office365SyncStatus = "Send failed (Graph + SMTP) — \(short)"
                        return
                    }
                }
            }
            insertLocalSent(draft)
            office365SyncStatus = status
            office365LastError = nil
        } catch {
            let detail = error.localizedDescription
            office365LastError = detail
            let short = detail.count > 280 ? String(detail.prefix(277)) + "…" : detail
            office365SyncStatus = "Send failed — \(short)"
        }
    }

    private func sendOffice365ViaSMTP(draft: ComposeDraft, account: MailAccount) async throws -> String {
        let smtpToken = try await MSALAuthService.shared.acquireSMTPAccessToken(
            interactiveIfNeeded: true,
            loginHint: account.email
        )
        return try await MicrosoftGraphMailService.sendViaSMTPOAuth(
            accessToken: smtpToken,
            mailboxEmail: account.email,
            draft: draft,
            signature: account.signature
        )
    }

    private enum Office365SyncTimeoutError: LocalizedError {
        case timedOut(seconds: Int)
        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "Microsoft 365 sync timed out after \(seconds)s. Use Cancel sync if buttons stay disabled, then try Sync now again."
            }
        }
    }

    private func withOffice365SyncTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Office365SyncTimeoutError.timedOut(seconds: Int(seconds))
            }
            guard let value = try await group.next() else {
                throw Office365SyncTimeoutError.timedOut(seconds: Int(seconds))
            }
            group.cancelAll()
            return value
        }
    }


    // MARK: - Sync upsert / dedupe

    /// Merge fetched live mail by `remoteID` (fallback: internetMessageId). Preserves local UUID,
    /// named flags, and snooze. Prunes stale rows only in successfully synced folders, and never
    /// when `fetched` is empty (keeps existing mail on empty/error responses).
    @discardableResult
    private func upsertSyncedMessages(
        accountID: UUID,
        syncedFolderIDs: Set<UUID>,
        fetched: [MailMessage],
        previousIDs: Set<UUID>
    ) -> [MailMessage] {
        var byRemote: [String: Int] = [:]
        var byInternet: [String: Int] = [:]
        for (idx, m) in messages.enumerated() where m.accountID == accountID {
            if let r = normalizedRemoteID(m.remoteID) {
                byRemote[r] = idx
            }
            if let i = normalizedInternetMessageId(m.internetMessageId) {
                byInternet[i] = idx
            }
        }

        var seenRemote = Set<String>()
        var seenInternet = Set<String>()
        var newOnes: [MailMessage] = []
        for var incoming in fetched {
            let remoteKey = normalizedRemoteID(incoming.remoteID)
            let internetKey = normalizedInternetMessageId(incoming.internetMessageId)

            var matchIndex: Int?
            if let remoteKey, let idx = byRemote[remoteKey] {
                matchIndex = idx
            } else if let internetKey, let idx = byInternet[internetKey] {
                matchIndex = idx
            }

            if let idx = matchIndex, messages.indices.contains(idx) {
                let local = messages[idx]
                incoming.id = local.id
                // Keep local named-flag / snooze state.
                if local.isFlagged {
                    incoming.isFlagged = true
                    incoming.flagID = local.flagID ?? incoming.flagID
                } else if local.flagID != nil {
                    incoming.flagID = local.flagID
                    incoming.isFlagged = true
                }
                if let until = local.snoozeUntil {
                    incoming.snoozeUntil = until
                    incoming.folderID = local.folderID
                }
                // Keep server read state from fetch; local read already matches if same id path.
                if local.isRead && !incoming.isRead {
                    // User may have marked read locally before server caught up — keep read.
                    incoming.isRead = true
                }
                messages[idx] = incoming
                if let remoteKey {
                    byRemote[remoteKey] = idx
                    seenRemote.insert(remoteKey)
                }
                if let internetKey {
                    byInternet[internetKey] = idx
                    seenInternet.insert(internetKey)
                }
            } else {
                if !previousIDs.contains(incoming.id) && !incoming.isRead {
                    newOnes.append(incoming)
                }
                messages.append(incoming)
                let idx = messages.count - 1
                if let remoteKey {
                    byRemote[remoteKey] = idx
                    seenRemote.insert(remoteKey)
                }
                if let internetKey {
                    byInternet[internetKey] = idx
                    seenInternet.insert(internetKey)
                }
            }
        }

        // Drop stale copies only in folders that were intentionally replaced by this
        // successful fetch. Never prune when the fetch set is empty — an empty/error
        // response must not wipe existing Gmail or Kale Yeah mail.
        if !fetched.isEmpty, !syncedFolderIDs.isEmpty {
            let fetchedIDs = Set(fetched.map(\.id))
            messages.removeAll { m in
                guard m.accountID == accountID else { return false }
                guard syncedFolderIDs.contains(m.folderID) else { return false }
                guard m.snoozeUntil == nil else { return false }
                // Keep rows we just upserted / appended in this pass.
                if fetchedIDs.contains(m.id) { return false }
                if let r = normalizedRemoteID(m.remoteID) {
                    return !seenRemote.contains(r)
                }
                if let i = normalizedInternetMessageId(m.internetMessageId) {
                    return !seenInternet.contains(i)
                }
                // Legacy rows without remote keys: remove from synced folders on replace.
                return true
            }
        }

        deduplicateMessagesByRemoteID(accountID: accountID)
        messages.sort { $0.receivedAt > $1.receivedAt }
        return newOnes
    }

    /// Collapse duplicate rows that share remoteID / internetMessageId within an account.
    /// Keeps the copy with local flag/snooze state when present, otherwise the newest.
    func deduplicateMessagesByRemoteID(accountID: UUID? = nil) {
        var keep: [MailMessage] = []
        var chosenRemote: [String: Int] = [:]
        var chosenInternet: [String: Int] = [:]

        for msg in messages {
            if let accountID, msg.accountID != accountID {
                keep.append(msg)
                continue
            }

            let remoteKey = normalizedRemoteID(msg.remoteID).map { "\(msg.accountID.uuidString)|r|\($0)" }
            let internetKey = normalizedInternetMessageId(msg.internetMessageId).map { "\(msg.accountID.uuidString)|i|\($0)" }

            if remoteKey == nil && internetKey == nil {
                keep.append(msg)
                continue
            }

            var existingIndex: Int?
            if let remoteKey, let idx = chosenRemote[remoteKey] {
                existingIndex = idx
            } else if let internetKey, let idx = chosenInternet[internetKey] {
                existingIndex = idx
            }

            if let idx = existingIndex {
                keep[idx] = preferredDuplicate(keep[idx], msg)
                let winner = keep[idx]
                if let remoteKey {
                    chosenRemote[remoteKey] = idx
                }
                if let ik = normalizedInternetMessageId(winner.internetMessageId).map({ "\(winner.accountID.uuidString)|i|\($0)" }) {
                    chosenInternet[ik] = idx
                }
            } else {
                let idx = keep.count
                keep.append(msg)
                if let remoteKey {
                    chosenRemote[remoteKey] = idx
                }
                if let internetKey {
                    chosenInternet[internetKey] = idx
                }
            }
        }

        if keep.count != messages.count {
            messages = keep
        }
    }

    private func preferredDuplicate(_ a: MailMessage, _ b: MailMessage) -> MailMessage {
        let aLocal = a.isFlagged || a.flagID != nil || a.snoozeUntil != nil
        let bLocal = b.isFlagged || b.flagID != nil || b.snoozeUntil != nil
        if aLocal != bLocal {
            return aLocal ? a : b
        }
        // Prefer the one that already has a remoteID populated.
        if (a.remoteID?.isEmpty == false) != (b.remoteID?.isEmpty == false) {
            return (a.remoteID?.isEmpty == false) ? a : b
        }
        return a.receivedAt >= b.receivedAt ? a : b
    }

    private func normalizedRemoteID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedInternetMessageId(_ value: String?) -> String? {
        guard let value else { return nil }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        trimmed = trimmed.lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Seed

    /// No demo accounts or sample messages — only shared smart folders.
    /// Live Gmail / Microsoft 365 shells are restored on launch when connected.
    private func seed() {
        accounts = []
        messages = []
        flags = MailFlag.defaults
        lastUsedFlagID = flags.first?.id
        folders = [
            MailFolder(id: approveFolderID, accountID: nil, name: "Approve", kind: .approve, sortOrder: -2, isPinned: true, isSmart: true),
            MailFolder(id: snoozedFolderID, accountID: nil, name: "Snoozed", kind: .snoozed, sortOrder: -1, isPinned: true, isSmart: true),
            MailFolder(id: junkFolderID, accountID: nil, name: "Junk", kind: .junk, sortOrder: 90, isPinned: false, isSmart: true),
            MailFolder(id: archiveFolderID, accountID: nil, name: "Archive", kind: .archive, sortOrder: 91, isPinned: false, isSmart: true),
            MailFolder(id: trashFolderID, accountID: nil, name: "Trash", kind: .trash, sortOrder: 92, isPinned: false, isSmart: true),
        ]
        applyPersistedDisplayNames()
    }
}
