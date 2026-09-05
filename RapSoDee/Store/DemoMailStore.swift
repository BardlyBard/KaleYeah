import Foundation
import Observation
import SwiftUI

@MainActor
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
    var emlImportProgress: EMLImportProgress?
    var emlImportIsRunning: Bool = false
    private var emlImportTask: Task<Void, Never>?
    /// Overall Graph sync budget (silent token + lightweight inbox/sent list).
    /// Raised from 45→90 after listLimit=200: token + multi-page Inbox/Sent needs headroom.
    private static let office365SyncTimeoutSeconds: TimeInterval = 90
    /// Silent token acquire must fail fast — never hang Settings on interactive auth during Sync.
    private static let office365TokenTimeoutSeconds: TimeInterval = 12
    /// Bumped on Cancel so in-flight sync abandons results without racing UI.
    private var office365SyncGeneration: Int = 0
    /// Cooperative cancel target for Graph/MSAL work (do not invalidate URLSession).
    private var office365InFlightTask: Task<Void, Never>?

    /// Last compose/send status shown in compose + toolbar (never silent).
    var outboundStatus: String = ""
    /// True when outboundStatus is an error the user must act on.
    var outboundIsError: Bool = false
    /// Bumped so delayed auto-clear does not wipe a newer banner.
    private var outboundStatusClearGeneration: Int = 0

    /// Universal toolbar sync busy (Gmail + M365).
    var isUniversalSyncing: Bool = false
    /// Prevent overlapping Sync all / auto-sync runs.
    private var syncAllInFlight: Bool = false

    /// Remote IDs deleted locally — sync must not resurrect them until the server also drops them
    /// (or the user undeletes on the server, in which case a later sync can clear the tombstone).
    private var deletedRemoteIDs: Set<String> = []

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
        loadMessageCacheFromDisk()
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
        let message = messages[i]
        let account = account(for: message.accountID)

        // Local: move to account Trash (or shared Trash) immediately so UI never waits on network.
        if let dest = folders.first(where: { $0.kind == .trash && $0.accountID == message.accountID }) {
            messages[i].folderID = dest.id
        } else {
            messages[i].folderID = trashFolderID
        }
        messages[i].snoozeUntil = nil

        if let remote = normalizedRemoteID(message.remoteID) {
            deletedRemoteIDs.insert(remote)
            MailMessageCache.saveDeletedRemoteIDs(deletedRemoteIDs)
        }
        persistMessageCache()

        // Server: Graph Deleted Items / IMAP Trash — fire and forget after local move.
        Task { await self.deleteMessageOnServer(message, account: account) }
    }

    private func deleteMessageOnServer(_ message: MailMessage, account: MailAccount?) async {
        guard let account else { return }
        guard let remote = normalizedRemoteID(message.remoteID),
              !remote.hasPrefix(Self.optimisticRemotePrefix) else { return }

        if account.isLiveOffice365 {
            do {
                let token = try await MSALAuthService.shared.acquireAccessToken(
                    interactiveIfNeeded: false,
                    loginHint: account.email
                )
                try await MicrosoftGraphMailService.deleteMessage(accessToken: token, graphMessageID: remote)
            } catch {
                // Keep tombstone + local trash; next sync still will not resurrect.
                office365LastError = "Delete failed: \(error.localizedDescription)"
            }
            return
        }

        if account.isLiveGmail {
            guard let password = KeychainCredentialStore.password(forEmail: account.email) else { return }
            do {
                try await GmailSyncService.deleteRemoteMessage(
                    email: account.email,
                    password: password,
                    remoteID: remote
                )
            } catch {
                gmailLastError = "Delete failed: \(error.localizedDescription)"
            }
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

    /// Resolve the live account for this draft — prefer accountID, then From address.
    private func liveAccountForCompose(_ draft: ComposeDraft) -> MailAccount? {
        if let account = account(for: draft.accountID), account.isLiveGmail || account.isLiveOffice365 {
            return account
        }
        let from = draft.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !from.isEmpty {
            if let byFrom = accounts.first(where: {
                $0.email.lowercased() == from && ($0.isLiveGmail || $0.isLiveOffice365)
            }) {
                return byFrom
            }
        }
        return nil
    }

    func clearOutboundStatus() {
        outboundStatusClearGeneration += 1
        outboundStatus = ""
        outboundIsError = false
    }

    private func setOutboundStatus(_ message: String, isError: Bool) {
        outboundStatus = message
        outboundIsError = isError
        outboundStatusClearGeneration += 1
        let generation = outboundStatusClearGeneration
        // Success banners auto-dismiss; errors stay until the user taps Dismiss / the banner.
        guard !isError, !message.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard generation == outboundStatusClearGeneration else { return }
            if !outboundIsError {
                outboundStatus = ""
            }
        }
    }

    /// Send mail. Always updates outboundStatus / provider status. Returns true only on success.
    @discardableResult
    func sendCompose(_ draft: ComposeDraft) async -> Bool {
        var draft = draft
        if let live = liveAccountForCompose(draft) {
            draft.accountID = live.id
            if draft.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.fromAddress = live.email
            }
            if live.isLiveGmail {
                return await sendGmailCompose(draft)
            }
            if live.isLiveOffice365 {
                return await sendOffice365Compose(draft)
            }
        }
        // Demo / non-live account — local Sent only.
        upsertOptimisticOutbound(draft)
        let msg = "Saved to local Sent (no live account for From)"
        setOutboundStatus(msg, isError: false)
        gmailSyncStatus = msg
        return true
    }

    private static let optimisticRemotePrefix = "local-"

    private func parseComposeAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func normalizedMailboxEmail(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let start = s.firstIndex(of: "<"), let end = s.firstIndex(of: ">"), start < end {
            s = String(s[s.index(after: start)..<end])
        }
        return s
    }

    private func draftIncludesSelf(_ draft: ComposeDraft, selfEmail: String) -> Bool {
        let selfNorm = normalizedMailboxEmail(selfEmail)
        guard !selfNorm.isEmpty else { return false }
        let recipients = (parseComposeAddresses(draft.to) + parseComposeAddresses(draft.cc))
            .map(normalizedMailboxEmail)
        return recipients.contains(selfNorm)
    }

    /// Immediately show Sent (and Inbox when mailing yourself) after a successful send.
    private func upsertOptimisticOutbound(_ draft: ComposeDraft) {
        let live = account(for: draft.accountID)
        ensureStandardMailFolders(
            for: draft.accountID,
            baseSort: live?.isLiveOffice365 == true ? -20 : (live?.isLiveGmail == true ? -10 : 0)
        )
        let selfEmail = (live?.email ?? draft.fromAddress)
        let toList = parseComposeAddresses(draft.to)
        let ccList = parseComposeAddresses(draft.cc)
        let includesSelf = draftIncludesSelf(draft, selfEmail: selfEmail)

        let bodyWithSig: String
        if let sig = live?.signature, !sig.isEmpty, !draft.body.contains(sig) {
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
        let now = Date()
        let token = UUID().uuidString
        let fromAddress = draft.fromAddress.isEmpty ? (live?.email ?? "") : draft.fromAddress
        let fromName = live?.name ?? "Me"
        let deliveredTo = live?.email ?? fromAddress

        if let sentID = folders.first(where: { $0.kind == .sent && $0.accountID == draft.accountID })?.id {
            messages.removeAll {
                $0.accountID == draft.accountID
                    && $0.folderID == sentID
                    && ($0.remoteID?.hasPrefix(Self.optimisticRemotePrefix) == true)
                    && $0.subject == draft.subject
                    && abs($0.receivedAt.timeIntervalSince(now)) < 120
            }
            messages.insert(
                MailMessage(
                    accountID: draft.accountID,
                    folderID: sentID,
                    fromName: fromName,
                    fromAddress: fromAddress,
                    toAddresses: toList,
                    ccAddresses: ccList,
                    subject: draft.subject,
                    snippet: String(bodyWithSig.prefix(120)),
                    body: bodyWithSig,
                    receivedAt: now,
                    isRead: true,
                    attachments: attachments,
                    deliveredTo: deliveredTo,
                    disposition: .normal,
                    isDraft: false,
                    remoteID: "\(Self.optimisticRemotePrefix)outbound:\(token)",
                    internetMessageId: "local-msgid:\(token)"
                ),
                at: 0
            )
        }

        if includesSelf,
           let inboxID = folders.first(where: { $0.kind == .inbox && $0.accountID == draft.accountID })?.id {
            messages.removeAll {
                $0.accountID == draft.accountID
                    && $0.folderID == inboxID
                    && ($0.remoteID?.hasPrefix(Self.optimisticRemotePrefix) == true)
                    && $0.subject == draft.subject
                    && abs($0.receivedAt.timeIntervalSince(now)) < 120
            }
            messages.insert(
                MailMessage(
                    accountID: draft.accountID,
                    folderID: inboxID,
                    fromName: fromName,
                    fromAddress: fromAddress,
                    toAddresses: toList,
                    ccAddresses: ccList,
                    subject: draft.subject,
                    snippet: String(bodyWithSig.prefix(120)),
                    body: bodyWithSig,
                    receivedAt: now,
                    isRead: false,
                    attachments: attachments,
                    deliveredTo: deliveredTo,
                    disposition: .normal,
                    isDraft: false,
                    remoteID: "\(Self.optimisticRemotePrefix)inbound:\(token)",
                    internetMessageId: "local-msgid:\(token)"
                ),
                at: 0
            )
        }

        messages.sort { $0.receivedAt > $1.receivedAt }
    }

    /// Quiet background refresh after send so Sent/Inbox pick up Graph/Gmail copies.
    private func kickQuietPostSendSync(accountID: UUID, includeInbox: Bool) {
        guard let account = account(for: accountID) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if account.isLiveOffice365 {
                await syncOffice365Now()
                if includeInbox {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await syncOffice365Now()
                }
            } else if account.isLiveGmail {
                await syncGmailNow()
                if includeInbox {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await syncGmailNow()
                }
            }
        }
    }

    /// Folder switch to Sent/Inbox triggers a quiet live sync so recent mail appears.
    func quietSyncIfNeeded(for selection: LadderSelection) async {
        switch selection {
        case .folder(let id):
            guard let folder = folder(for: id), folder.kind == .sent || folder.kind == .inbox else { return }
            guard let accountID = folder.accountID, let account = account(for: accountID) else { return }
            if isAnyLiveSyncing { return }
            if account.isLiveOffice365 {
                await syncOffice365Now()
            } else if account.isLiveGmail {
                await syncGmailNow()
            }
        case .unifiedInbox, .accountInbox, .approve:
            break
        }
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
        Task { @MainActor in
            _ = await sendCompose(draft)
        }
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
            persistMessageCache()
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

    @discardableResult
    private func sendGmailCompose(_ draft: ComposeDraft) async -> Bool {
        guard let account = account(for: draft.accountID), account.isLiveGmail else {
            upsertOptimisticOutbound(draft)
            setOutboundStatus("Saved to local Sent (Gmail account missing)", isError: false)
            return true
        }
        let to = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !to.isEmpty else {
            let msg = "Send failed — add at least one To recipient"
            gmailLastError = msg
            gmailSyncStatus = msg
            setOutboundStatus(msg, isError: true)
            return false
        }
        guard let password = KeychainCredentialStore.password(forEmail: account.email) else {
            let msg = "Send failed — missing Gmail App Password (Settings → Accounts)"
            gmailLastError = msg
            gmailNeedsSetup = true
            gmailSyncStatus = msg
            setOutboundStatus(msg, isError: true)
            return false
        }
        gmailIsSyncing = true
        gmailSyncStatus = "Sending via Gmail SMTP as \(account.email)…"
        setOutboundStatus(gmailSyncStatus, isError: false)
        defer { gmailIsSyncing = false }
        do {
            try await GmailSyncService.send(
                email: account.email,
                password: password,
                draft: draft,
                signature: account.signature
            )
            upsertOptimisticOutbound(draft)
            gmailSyncStatus = "Sent via Gmail SMTP → \(to.prefix(2).joined(separator: ", "))"
            gmailLastError = nil
            setOutboundStatus(gmailSyncStatus, isError: false)
            kickQuietPostSendSync(accountID: account.id, includeInbox: draftIncludesSelf(draft, selfEmail: account.email))
            return true
        } catch {
            let detail = error.localizedDescription
            gmailLastError = detail
            let short = detail.count > 200 ? String(detail.prefix(197)) + "…" : detail
            gmailSyncStatus = "Send failed — \(short)"
            setOutboundStatus(gmailSyncStatus, isError: true)
            return false
        }
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
        office365InFlightTask?.cancel()
        office365SyncGeneration += 1
        let generation = office365SyncGeneration
        let work = Task { @MainActor in
            await self.performSignInMicrosoft365(generation: generation)
        }
        office365InFlightTask = work
        await work.value
        if office365SyncGeneration == generation {
            office365InFlightTask = nil
        }
    }

    private func performSignInMicrosoft365(generation: Int) async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Signing in with Microsoft…"
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
            }
        }
        do {
            // Bound interactive sign-in so a hung ASWebAuthenticationSession cannot spin forever.
            _ = try await withOffice365SyncTimeout(seconds: 90) {
                try await MSALAuthService.shared.signIn(loginHint: Office365Defaults.defaultEmail)
            }
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
            }
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            guard generation == office365SyncGeneration else { return }
            _ = ensureOffice365Account(email: email, id: Office365SyncService.storedAccountID() ?? UUID())
            office365NeedsSetup = false
            office365SyncStatus = "Signed in as \(email)"
            office365IsSyncing = false
            office365SyncStartedAt = nil
            await syncOffice365Now()
        } catch is CancellationError {
            if generation == office365SyncGeneration {
                office365SyncStatus = "Sign-in cancelled"
            }
        } catch is Office365SyncTimeoutError {
            guard generation == office365SyncGeneration else { return }
            _ = MSALAuthService.cancelPendingAuth()
            office365LastError = "Sign-in timed out."
            office365SyncStatus = "Sync timed out — try again"
        } catch {
            guard generation == office365SyncGeneration else { return }
            if Self.isCancelLike(error) {
                office365SyncStatus = "Sign-in cancelled"
                return
            }
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
        office365InFlightTask?.cancel()
        office365SyncGeneration += 1
        let generation = office365SyncGeneration
        let work = Task { @MainActor in
            await self.performSignInMicrosoft365WithDeviceCode(generation: generation, onPrompt: onPrompt)
        }
        office365InFlightTask = work
        await work.value
        if office365SyncGeneration == generation {
            office365InFlightTask = nil
        }
    }

    private func performSignInMicrosoft365WithDeviceCode(
        generation: Int,
        onPrompt: @MainActor @escaping (MSALDeviceCodePrompt) -> Void
    ) async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Starting device code sign-in…"
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
            }
        }
        do {
            _ = try await MSALAuthService.shared.signInWithDeviceCode(
                loginHint: Office365Defaults.defaultEmail,
                onPrompt: onPrompt
            )
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
            }
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
            guard generation == office365SyncGeneration else { return }
            _ = ensureOffice365Account(email: email, id: Office365SyncService.storedAccountID() ?? UUID())
            office365NeedsSetup = false
            office365SyncStatus = "Signed in as \(email) (device code)"
            office365IsSyncing = false
            office365SyncStartedAt = nil
            await syncOffice365Now()
        } catch is CancellationError {
            if generation == office365SyncGeneration {
                office365SyncStatus = "Sign-in cancelled"
            }
        } catch {
            guard generation == office365SyncGeneration else { return }
            if Self.isCancelLike(error) {
                office365SyncStatus = "Sign-in cancelled"
                return
            }
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
    /// Crash-safe: bump generation, cancel in-flight Task, clear busy flags on MainActor.
    /// Never invalidateAndCancel shared URLSession. MSAL cancel is soft (flag + web-auth
    /// dismiss); acquireToken* continuations resume at most once (Cancel crash fix).
    func cancelOffice365Sync() {
        office365SyncGeneration += 1
        let task = office365InFlightTask
        office365InFlightTask = nil
        task?.cancel()
        // Soft-cancel only — do not tear down Graph URLSession mid-callback.
        _ = MSALAuthService.cancelPendingAuth()
        // Toolbar Sync all holds isUniversalSyncing until syncOffice365Now returns; if that
        // await is stuck behind hung MSAL, clear universal busy here or spinner never dies.
        syncAllInFlight = false
        isUniversalSyncing = false
        office365IsSyncing = false
        office365SyncStartedAt = nil
        office365SyncStatus = "Sync / sign-in cancelled"
        office365LastError = "Cancelled. Tap Sync now, or Sign in with device code if Microsoft sign-in expired."
    }

    func syncOffice365Now() async {
        // Cancel any prior run cooperatively, then start a fresh generation-scoped task.
        office365InFlightTask?.cancel()
        office365SyncGeneration += 1
        let generation = office365SyncGeneration
        let work = Task { @MainActor in
            await self.performOffice365Sync(generation: generation)
        }
        office365InFlightTask = work
        await work.value
        if office365SyncGeneration == generation {
            office365InFlightTask = nil
        }
    }

    private func performOffice365Sync(generation: Int) async {
        restoreOffice365AccountShellIfNeeded()
        guard generation == office365SyncGeneration, !Task.isCancelled else { return }

        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Syncing Microsoft 365 via Graph (headers only)…"
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
            }
        }

        do {
            struct SyncPayload: Sendable {
                var email: String
                var messages: [MailMessage]
                var status: String
                var prunableFolderIDs: Set<UUID>
                var accountID: UUID
                var accountEmailHint: String
                var previousIDs: Set<UUID>
            }

            // Hard overall deadline — auto-stops so Cancel is never required for a hung spinner.
            let payload: SyncPayload = try await withOffice365SyncTimeout(seconds: Self.office365SyncTimeoutSeconds) {
                try Task.checkCancellation()
                if self.office365Account() == nil {
                    let token = try await self.withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                        try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false)
                    }
                    try Task.checkCancellation()
                    guard generation == self.office365SyncGeneration else { throw CancellationError() }
                    let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                    try Task.checkCancellation()
                    guard generation == self.office365SyncGeneration else { throw CancellationError() }
                    _ = self.ensureOffice365Account(email: email)
                }
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
                guard let account = self.office365Account() else {
                    throw MSALAuthError.noAccount
                }
                guard let folderIDs = self.liveFolderIDs(for: account.id) else {
                    throw Office365SyncTimeoutError.foldersMissing
                }
                let previousIDs = Set(self.messages.filter { $0.accountID == account.id }.map(\.id))
                let accountID = account.id
                let accountEmailHint = account.email

                let token = try await self.withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                    try await MSALAuthService.shared.acquireAccessToken(
                        interactiveIfNeeded: false,
                        loginHint: accountEmailHint
                    )
                }
                try Task.checkCancellation()
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
                let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                try Task.checkCancellation()
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
                let (fetched, result, prunable) = try await MicrosoftGraphMailService.sync(
                    accessToken: token,
                    accountID: accountID,
                    folderIDs: folderIDs,
                    accountEmail: email
                )
                try Task.checkCancellation()
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
                return SyncPayload(
                    email: email,
                    messages: fetched,
                    status: result.status,
                    prunableFolderIDs: prunable,
                    accountID: accountID,
                    accountEmailHint: accountEmailHint,
                    previousIDs: previousIDs
                )
            }

            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            if payload.email.lowercased() != payload.accountEmailHint.lowercased() {
                _ = ensureOffice365Account(email: payload.email, id: payload.accountID)
            }
            let newOnes = upsertSyncedMessages(
                accountID: payload.accountID,
                syncedFolderIDs: payload.prunableFolderIDs,
                fetched: payload.messages,
                previousIDs: payload.previousIDs
            )
            office365SyncStatus = payload.status
            office365NeedsSetup = false
            office365LastError = nil
            for msg in newOnes.prefix(3) {
                applyNotificationPolicy(for: msg)
            }
            persistMessageCache()
        } catch is CancellationError {
            if generation == office365SyncGeneration {
                office365SyncStatus = "Sync cancelled"
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if generation == office365SyncGeneration {
                office365SyncStatus = "Sync cancelled"
            }
        } catch let timeout as Office365SyncTimeoutError {
            guard generation == office365SyncGeneration else { return }
            switch timeout {
            case .timedOut(let seconds):
                _ = MSALAuthService.cancelPendingAuth()
                // Clear any universal toolbar busy that may still be awaiting this sync.
                syncAllInFlight = false
                isUniversalSyncing = false
                if seconds <= Int(Self.office365TokenTimeoutSeconds) + 1 {
                    office365NeedsSetup = true
                    office365LastError = "Silent Microsoft token timed out. Use Settings → Sign in with device code."
                    office365SyncStatus = "Microsoft sign-in expired — use Sign in with device code"
                } else {
                    office365LastError = "Sync timed out after \(seconds)s. If this keeps happening, Sign in with device code."
                    office365SyncStatus = "Sync timed out — try again"
                }
            case .foldersMissing:
                office365NeedsSetup = true
                office365LastError = "Microsoft 365 folders missing — try Sign out, then Sign in with device code."
                office365SyncStatus = "Sync failed — folders missing"
            }
        } catch {
            guard generation == office365SyncGeneration else { return }
            if Self.isCancelLike(error) {
                office365SyncStatus = "Sync cancelled"
                return
            }
            let detail = error.localizedDescription
            office365LastError = detail
            let short = detail.count > 280 ? String(detail.prefix(277)) + "…" : detail
            office365SyncStatus = "Sync failed — \(short)"
            let lower = detail.lowercased()
            if Self.isSilentAuthFailure(error) || lower.contains("folders missing") || lower.contains("client id") {
                office365NeedsSetup = true
                if lower.contains("folders missing") {
                    office365SyncStatus = "Sync failed — folders missing"
                    office365LastError = "Microsoft 365 folders missing — try Sign out, then Sign in with device code."
                } else {
                    office365SyncStatus = "Microsoft sign-in expired — use Sign in with device code"
                    office365LastError = "Silent token failed. Open Settings → Sign in with device code.\n\(short)"
                }
            }
        }
    }


    // MARK: - EML import (Microsoft 365)

    func cancelEMLImport() {
        emlImportTask?.cancel()
        emlImportTask = nil
        emlImportIsRunning = false
        if var p = emlImportProgress {
            p.statusLine = "Cancelled — \(p.imported)/\(p.total) imported"
            emlImportProgress = p
        }
        office365SyncStatus = emlImportProgress?.statusLine ?? "EML import cancelled"
    }

    /// Pick sources via NSOpenPanel, import into Graph folder, then Sync.
    /// Uses silent token; on expiry runs device-code via `onDeviceCodePrompt`.
    func importEMLIntoMicrosoft365(
        destination: EMLImportDestination = .inbox,
        customFolderID: String? = nil,
        onDeviceCodePrompt: (@MainActor (MSALDeviceCodePrompt) -> Void)? = nil
    ) async {
        if emlImportIsRunning { return }
        guard let urls = EMLImportService.pickEMLSources(), !urls.isEmpty else {
            office365SyncStatus = "EML import cancelled"
            return
        }
        let files = EMLImportService.collectEMLFiles(from: urls)
        guard !files.isEmpty else {
            office365SyncStatus = "No .eml files found in selection"
            office365LastError = "Select a folder containing .eml files, or individual .eml files."
            return
        }

        let folderID: String
        if destination == .custom {
            let custom = (customFolderID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !custom.isEmpty else {
                office365LastError = "Enter a Graph mailFolder id for Custom destination."
                return
            }
            folderID = custom
        } else {
            folderID = destination.wellKnownName ?? "inbox"
        }

        emlImportIsRunning = true
        emlImportProgress = .empty(total: files.count)
        office365LastError = nil
        office365SyncStatus = "Importing \(files.count) EML file(s) into \(destination.title)…"

        let work = Task { @MainActor in
            defer {
                self.emlImportIsRunning = false
                self.emlImportTask = nil
            }
            do {
                var token: String
                do {
                    token = try await MSALAuthService.shared.acquireAccessToken(
                        interactiveIfNeeded: false,
                        loginHint: Office365Defaults.defaultEmail
                    )
                } catch {
                    guard let onPrompt = onDeviceCodePrompt else { throw error }
                    self.office365SyncStatus = "Sign-in expired — starting device code for EML import…"
                    token = try await MSALAuthService.shared.signInWithDeviceCode(
                        loginHint: Office365Defaults.defaultEmail,
                        onPrompt: onPrompt
                    )
                }
                try Task.checkCancellation()

                let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                _ = self.ensureOffice365Account(email: email)

                let progress = await EMLImportService.importFiles(
                    files,
                    accessToken: token,
                    destinationFolderID: folderID
                ) { prog in
                    self.emlImportProgress = prog
                    self.office365SyncStatus = prog.statusLine
                }
                self.emlImportProgress = progress
                self.office365SyncStatus = progress.statusLine
                if !progress.failures.isEmpty {
                    let preview = progress.failures.prefix(3).map { "\($0.file): \($0.reason)" }.joined(separator: " | ")
                    self.office365LastError = preview
                } else {
                    self.office365LastError = nil
                }

                // Refresh RapSoDee list from Graph so imported mail appears.
                if progress.imported > 0 || progress.skippedDuplicates > 0 {
                    await self.syncOffice365Now()
                    if self.office365SyncStatus.localizedCaseInsensitiveContains("synced") {
                        self.office365SyncStatus = "\(progress.statusLine) — \(self.office365SyncStatus)"
                    }
                }
            } catch is CancellationError {
                self.office365SyncStatus = "EML import cancelled"
            } catch {
                if Self.isCancelLike(error) {
                    self.office365SyncStatus = "EML import cancelled"
                    return
                }
                let detail = error.localizedDescription
                self.office365LastError = detail
                self.office365SyncStatus = "EML import failed — \(String(detail.prefix(200)))"
                if Self.isSilentAuthFailure(error) {
                    self.office365NeedsSetup = true
                    self.office365SyncStatus = "Microsoft sign-in expired — use Sign in with device code, then Import EML again"
                }
            }
        }
        emlImportTask = work
        await work.value
    }

    /// Load full Graph body when opening a Kale Yeah message (list sync uses bodyPreview only).
    func ensureOffice365BodyLoaded(messageID: UUID) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[idx]
        guard let account = account(for: message.accountID), account.isLiveOffice365 else { return }
        guard let remoteID = message.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty else { return }
        if message.body.count > max(message.snippet.count + 40, 200) { return }
        let generation = office365SyncGeneration
        do {
            let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false, loginHint: account.email)
            }
            guard generation == office365SyncGeneration else { return }
            let loaded = try await MicrosoftGraphMailService.fetchMessageBody(accessToken: token, graphMessageID: remoteID)
            guard generation == office365SyncGeneration else { return }
            guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[i].body = loaded.body
            messages[i].isHTML = loaded.isHTML
        } catch {
            if !Self.isCancelLike(error) {
                NSLog("Office365 body fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private static let signInExpiredSendMessage = "Sign in expired — use Settings → Sign in with device code"

    /// Send must never open MSAL interactive / browser auth. Silent token only.
    private func failSendSignInExpired(_ detail: String? = nil) {
        office365NeedsSetup = true
        let msg = Self.signInExpiredSendMessage
        office365SyncStatus = msg
        setOutboundStatus(msg, isError: true)
        if let detail, !detail.isEmpty {
            office365LastError = "\(msg)\n\(detail)"
        } else {
            office365LastError = msg
        }
    }

    private static func isSilentAuthFailure(_ error: Error) -> Bool {
        if let auth = error as? MSALAuthError {
            switch auth {
            case .noAccount, .missingClientID:
                return true
            case .cancelled, .noPresentingWindow:
                return false
            case .underlying(let message):
                return Self.looksLikeSilentAuthMessage(message)
            }
        }
        return Self.looksLikeSilentAuthMessage(error.localizedDescription)
    }

    /// Tight match — do not treat arbitrary "expired" delivery text as auth failure.
    private static func looksLikeSilentAuthMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("interaction_required")
            || lower.contains("consent_required")
            || lower.contains("login_required")
            || lower.contains("login required")
            || lower.contains("not signed")
            || lower.contains("no account")
            || lower.contains("missing client")
            || lower.contains("client id")
            || lower.contains("silent token")
        {
            return true
        }
        // Token / sign-in expiry only (avoid matching unrelated "expired" strings).
        if lower.contains("token") && lower.contains("expired") { return true }
        if lower.contains("sign-in expired") || lower.contains("signin expired") { return true }
        if lower.contains("session expired") || lower.contains("authentication_expired") { return true }
        return false
    }

    private func sendOffice365ViaGraph(draft: ComposeDraft, account: MailAccount) async throws -> String {
        // Silent only — never acquireTokenInteractive from Send.
        let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
            try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false, loginHint: account.email)
        }
        let fromEmail = draft.fromAddress.isEmpty ? account.email : draft.fromAddress
        return try await MicrosoftGraphMailService.sendMail(
            accessToken: token,
            draft: draft,
            fromEmail: fromEmail,
            mailboxEmail: account.email,
            signature: account.signature
        )
    }

    @discardableResult
    private func sendOffice365Compose(_ draft: ComposeDraft) async -> Bool {
        guard let account = account(for: draft.accountID), account.isLiveOffice365 else {
            upsertOptimisticOutbound(draft)
            setOutboundStatus("Saved to local Sent (Microsoft 365 account missing)", isError: false)
            return true
        }
        let toList = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !toList.isEmpty else {
            let msg = "Send failed — add at least one To recipient"
            office365LastError = msg
            office365SyncStatus = msg
            setOutboundStatus(msg, isError: true)
            return false
        }
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        let toPreview = toList.prefix(2).joined(separator: ", ")
        let preferSMTP = MSALAppConfig.preferSMTPSend
        office365SyncStatus = preferSMTP
            ? "Sending via SMTP XOAUTH2 as \(account.email) → \(toPreview)…"
            : "Sending via Graph draft→send as \(account.email) → \(toPreview)…"
        setOutboundStatus(office365SyncStatus, isError: false)
        office365LastError = nil
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        do {
            let status: String
            if preferSMTP {
                // Prefer SMTP, but never silent-fail: if SMTP silent token/auth fails, try Graph.
                do {
                    status = try await sendOffice365ViaSMTP(draft: draft, account: account)
                } catch {
                    if error is Office365SyncTimeoutError || Self.isSilentAuthFailure(error) {
                        let smtpDetail = error.localizedDescription
                        office365SyncStatus = "SMTP XOAUTH2 unavailable — trying Graph draft→send… (\(String(smtpDetail.prefix(100))))"
                        setOutboundStatus(office365SyncStatus, isError: false)
                        do {
                            status = try await sendOffice365ViaGraph(draft: draft, account: account)
                        } catch {
                            if error is Office365SyncTimeoutError || Self.isSilentAuthFailure(error) {
                                failSendSignInExpired("SMTP: \(smtpDetail)\nGraph: \(error.localizedDescription)")
                                return false
                            }
                            let graphDetail = error.localizedDescription
                            office365LastError = "SMTP: \(smtpDetail)\nGraph: \(graphDetail)"
                            let short = graphDetail.count > 200 ? String(graphDetail.prefix(197)) + "…" : graphDetail
                            office365SyncStatus = "Send failed (SMTP + Graph) — \(short)"
                            setOutboundStatus(office365SyncStatus, isError: true)
                            return false
                        }
                    } else {
                        let detail = error.localizedDescription
                        office365LastError = detail
                        let short = detail.count > 280 ? String(detail.prefix(277)) + "…" : detail
                        office365SyncStatus = "Send failed (SMTP) — \(short)"
                        setOutboundStatus(office365SyncStatus, isError: true)
                        return false
                    }
                }
            } else {
                do {
                    status = try await sendOffice365ViaGraph(draft: draft, account: account)
                } catch {
                    if error is Office365SyncTimeoutError || Self.isSilentAuthFailure(error) {
                        failSendSignInExpired(error.localizedDescription)
                        return false
                    }
                    // Graph API failure → try SMTP OAuth. Still silent-only for tokens.
                    let graphDetail = error.localizedDescription
                    office365SyncStatus = "Graph send failed — trying SMTP XOAUTH2… (\(String(graphDetail.prefix(120))))"
                    setOutboundStatus(office365SyncStatus, isError: false)
                    do {
                        status = try await sendOffice365ViaSMTP(draft: draft, account: account)
                    } catch {
                        if error is Office365SyncTimeoutError || Self.isSilentAuthFailure(error) {
                            failSendSignInExpired("Graph: \(graphDetail)\nSMTP: \(error.localizedDescription)")
                            return false
                        }
                        let smtpDetail = error.localizedDescription
                        office365LastError = "Graph: \(graphDetail)\nSMTP: \(smtpDetail)"
                        let short = smtpDetail.count > 200 ? String(smtpDetail.prefix(197)) + "…" : smtpDetail
                        office365SyncStatus = "Send failed (Graph + SMTP) — \(short)"
                        setOutboundStatus(office365SyncStatus, isError: true)
                        return false
                    }
                }
            }
            upsertOptimisticOutbound(draft)
            office365SyncStatus = status
            office365LastError = nil
            setOutboundStatus(status, isError: false)
            kickQuietPostSendSync(accountID: account.id, includeInbox: draftIncludesSelf(draft, selfEmail: account.email))
            return true
        } catch {
            if error is Office365SyncTimeoutError || Self.isSilentAuthFailure(error) {
                failSendSignInExpired(error.localizedDescription)
                return false
            }
            let detail = error.localizedDescription
            office365LastError = detail
            let short = detail.count > 280 ? String(detail.prefix(277)) + "…" : detail
            office365SyncStatus = "Send failed — \(short)"
            setOutboundStatus(office365SyncStatus, isError: true)
            return false
        }
    }

    private func sendOffice365ViaSMTP(draft: ComposeDraft, account: MailAccount) async throws -> String {
        // Silent only — never open browser / interactive MSAL from Send.
        let smtpToken = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
            try await MSALAuthService.shared.acquireSMTPAccessToken(
                interactiveIfNeeded: false,
                loginHint: account.email
            )
        }
        return try await MicrosoftGraphMailService.sendViaSMTPOAuth(
            accessToken: smtpToken,
            mailboxEmail: account.email,
            draft: draft,
            signature: account.signature
        )
    }

    private enum Office365SyncTimeoutError: LocalizedError {
        case timedOut(seconds: Int)
        case foldersMissing
        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "Sync timed out after \(seconds)s — try again"
            case .foldersMissing:
                return "Microsoft 365 folders missing"
            }
        }
    }

    private static func isCancelLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        if let auth = error as? MSALAuthError, case .cancelled = auth { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return false
    }

    /// Race operation against a hard deadline. Timeout must return even if MSAL/Graph
    /// never completes — do NOT use TaskGroup (Swift waits for cancelled children on exit,
    /// so a hung acquireTokenSilent left the Sync spinner forever after the deadline "won").
    /// Cancel / soft-cancel MSAL without tearing down URLSession.
    private func withOffice365SyncTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let secondsInt = Int(seconds)
        let gate = Office365TimeoutGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task { @MainActor in
                do {
                    let value = try await operation()
                    gate.complete { continuation.resume(returning: value) }
                } catch {
                    gate.complete { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.complete {
                    work.cancel()
                    _ = MSALAuthService.cancelPendingAuth()
                    continuation.resume(throwing: Office365SyncTimeoutError.timedOut(seconds: secondsInt))
                }
            }
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
        // Folder-scoped: Sent + Inbox self-sends share internetMessageId but are distinct.
        var byInternetFolder: [String: Int] = [:]
        for (idx, m) in messages.enumerated() where m.accountID == accountID {
            if let r = normalizedRemoteID(m.remoteID) {
                byRemote[r] = idx
            }
            if let i = normalizedInternetMessageId(m.internetMessageId) {
                byInternetFolder["\(m.folderID.uuidString)|\(i)"] = idx
            }
        }

        var seenRemote = Set<String>()
        var seenInternetFolder = Set<String>()
        var newOnes: [MailMessage] = []
        // Drop tombstoned remotes from the fetch set so sync cannot resurrect deleted mail.
        let activeFetched = fetched.filter { msg in
            guard let r = normalizedRemoteID(msg.remoteID) else { return true }
            return !deletedRemoteIDs.contains(r)
        }
        // Clear this account's tombstones once the server no longer returns them.
        // While they still appear, activeFetched keeps suppressing resurrection.
        // After clear, an undelete on the server can bring the message back on a later sync.
        if !fetched.isEmpty {
            let fetchedRemotes = Set(fetched.compactMap { normalizedRemoteID($0.remoteID) })
            let localRemotes = Set(messages.compactMap { m -> String? in
                guard m.accountID == accountID else { return nil }
                return normalizedRemoteID(m.remoteID)
            })
            let cleared = deletedRemoteIDs.filter { tomb in
                (localRemotes.contains(tomb) || fetchedRemotes.contains(tomb)) && !fetchedRemotes.contains(tomb)
            }
            if !cleared.isEmpty {
                deletedRemoteIDs.subtract(cleared)
                MailMessageCache.saveDeletedRemoteIDs(deletedRemoteIDs)
            }
        }
        for var incoming in activeFetched {
            let remoteKey = normalizedRemoteID(incoming.remoteID)
            let internetKey = normalizedInternetMessageId(incoming.internetMessageId)
            let internetFolderKey = internetKey.map { "\(incoming.folderID.uuidString)|\($0)" }

            var matchIndex: Int?
            if let remoteKey, let idx = byRemote[remoteKey] {
                matchIndex = idx
            } else if let internetFolderKey, let idx = byInternetFolder[internetFolderKey] {
                matchIndex = idx
            } else if let internetKey {
                // Prefer replacing an optimistic placeholder in the same folder.
                if let idx = messages.firstIndex(where: {
                    $0.accountID == accountID
                        && $0.folderID == incoming.folderID
                        && ($0.remoteID?.hasPrefix(Self.optimisticRemotePrefix) == true)
                        && $0.subject == incoming.subject
                        && normalizedMailboxEmail($0.fromAddress) == normalizedMailboxEmail(incoming.fromAddress)
                        && abs($0.receivedAt.timeIntervalSince(incoming.receivedAt)) < 300
                }) {
                    matchIndex = idx
                }
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
                if let internetFolderKey {
                    byInternetFolder[internetFolderKey] = idx
                    seenInternetFolder.insert(internetFolderKey)
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
                if let internetFolderKey {
                    byInternetFolder[internetFolderKey] = idx
                    seenInternetFolder.insert(internetFolderKey)
                }
            }
        }

        // Drop optimistic placeholders superseded by a real server row in the same folder.
        if !fetched.isEmpty {
            messages.removeAll { m in
                guard m.accountID == accountID else { return false }
                guard let r = normalizedRemoteID(m.remoteID), r.hasPrefix(Self.optimisticRemotePrefix) else { return false }
                return fetched.contains { server in
                    server.folderID == m.folderID
                        && server.subject == m.subject
                        && normalizedMailboxEmail(server.fromAddress) == normalizedMailboxEmail(m.fromAddress)
                        && abs(server.receivedAt.timeIntervalSince(m.receivedAt)) < 300
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
                    // Keep optimistic local Sent/Inbox until a server copy replaces them.
                    if r.hasPrefix(Self.optimisticRemotePrefix) { return false }
                    return !seenRemote.contains(r)
                }
                if let i = normalizedInternetMessageId(m.internetMessageId) {
                    let key = "\(m.folderID.uuidString)|\(i)"
                    return !seenInternetFolder.contains(key)
                }
                // Legacy rows without remote keys: remove from synced folders on replace.
                return true
            }
        }

        deduplicateMessagesByRemoteID(accountID: accountID)
        messages.sort { $0.receivedAt > $1.receivedAt }
        return newOnes
    }

    /// Collapse duplicate rows that share remoteID, or internetMessageId within the same folder.
    /// Sent + Inbox self-sends share Message-ID but must remain distinct.
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
            let internetKey = normalizedInternetMessageId(msg.internetMessageId).map { "\(msg.accountID.uuidString)|\(msg.folderID.uuidString)|i|\($0)" }

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
                if let ik = normalizedInternetMessageId(winner.internetMessageId).map({ "\(winner.accountID.uuidString)|\(winner.folderID.uuidString)|i|\($0)" }) {
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

    // MARK: - Local message cache

    private func loadMessageCacheFromDisk() {
        deletedRemoteIDs = MailMessageCache.loadDeletedRemoteIDs()
        let cached = MailMessageCache.loadMessages()
        guard !cached.isEmpty else { return }
        // Prefer cache over empty launch; account shells already restored so folder IDs match.
        let knownAccountIDs = Set(accounts.map(\.id))
        let usable = cached.filter { knownAccountIDs.contains($0.accountID) }
        guard !usable.isEmpty else { return }
        if messages.isEmpty {
            messages = usable
        } else {
            // Merge cache under existing in-memory rows (should be empty at init).
            let existing = Set(messages.map(\.id))
            messages.append(contentsOf: usable.filter { !existing.contains($0.id) })
        }
        #if DEBUG
        print("RapSoDee: restored \(usable.count) cached messages")
        #endif
    }

    private func persistMessageCache() {
        MailMessageCache.saveMessages(messages)
        MailMessageCache.saveDeletedRemoteIDs(deletedRemoteIDs)
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

/// One-shot resume gate for Office365 hard timeouts (cannot nest types in generic closures).
fileprivate final class Office365TimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func complete(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        body()
    }
}

