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
    /// Bumped when per-mailbox MSAL/device-code auth changes so Settings re-renders Sign in vs Sync.
    private(set) var office365AuthRevision: Int = 0
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
        deduplicateLiveAccountShells()
        enforceCalliopeExcludedFromUnifiedInbox()
        loadMessageCacheFromDisk()
        ensureApproveMailbox()
        injectApproveTestDraftIfNeeded()
        gmailNeedsSetup = !GmailSyncService.hasKeychainCredentials(email: gmailAccount()?.email)
        office365NeedsSetup = MSALAppConfig.rememberedSignedInEmails.isEmpty && Office365SyncService.rememberedAccounts().isEmpty
    }

    func account(for id: UUID) -> MailAccount? { accounts.first { $0.id == id } }
    func folder(for id: UUID) -> MailFolder? { folders.first { $0.id == id } }

    func messages(for selection: LadderSelection) -> [MailMessage] {
        unsnoozeDue()
        var list: [MailMessage]
        switch selection {
        case .unifiedInbox:
            let included = Set(accounts.filter(\.contributesToUnifiedInbox).map(\.id))
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
        case .hasAttachments: list = list.filter { !$0.paperclipAttachments.isEmpty }
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
        guard let dest = folders.first(where: { $0.id == folderID }) else { return }
        // Cross-account filing is not supported (Gmail labels ≠ M365 folders).
        if let destAccount = dest.accountID, destAccount != messages[i].accountID {
            return
        }
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
        // Callie's account can never join One Inbox.
        if accounts[i].isCalliopeMailbox {
            accounts[i].isCalliope = true
            accounts[i].includeInUnifiedInbox = false
            return
        }
        accounts[i].includeInUnifiedInbox = include
    }

    /// Force every Callie shell out of One Inbox (load / sync / settings save).
    func enforceCalliopeExcludedFromUnifiedInbox() {
        for i in accounts.indices where accounts[i].isCalliopeMailbox {
            accounts[i].isCalliope = true
            accounts[i].includeInUnifiedInbox = false
        }
    }

    func updateSignature(accountID: UUID, signature: String) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].signature = MailSignatureFormatting.normalizeSignatureText(signature)
    }

    func updateSignatureLogo(accountID: UUID, path: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let previous = accounts[i].signatureLogoPath
        accounts[i].signatureLogoPath = path
        if let previous, previous != path {
            SignatureLogoStore.removeLogo(at: previous)
        }
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
        // Best-effort Graph rename for custom folders with a real remote id.
        let folder = folders[i]
        guard folder.kind == .custom,
              let remote = folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty,
              folder.accountID.flatMap({ account(for: $0)?.isLiveOffice365 }) == true
        else { return }
        Task { @MainActor in
            do {
                let token = try await MSALAuthService.shared.acquireAccessToken(
                    interactiveIfNeeded: false,
                    loginHint: Office365Defaults.defaultEmail
                )
                try await MicrosoftGraphMailService.renameMailFolder(
                    accessToken: token,
                    folderID: remote,
                    displayName: trimmed
                )
            } catch {
                // Local rename already applied; surface quietly.
                NSLog("Graph folder rename failed: \(error.localizedDescription)")
            }
        }
    }

    /// Create a mail folder on Graph and add it to the ladder / import picker.
    @discardableResult
    func createOffice365Folder(displayName: String, parentRemoteID: String? = nil) async -> MailFolder? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            office365LastError = "Folder name required"
            return nil
        }
        restoreOffice365AccountShellIfNeeded()
        guard let account = office365Account() else {
            office365LastError = "Sign in to Microsoft 365 first"
            office365NeedsSetup = true
            return nil
        }
        do {
            let token = try await MSALAuthService.shared.acquireAccessToken(
                interactiveIfNeeded: false,
                loginHint: account.email
            )
            let created = try await MicrosoftGraphMailService.createMailFolder(
                accessToken: token,
                displayName: name,
                parentFolderID: parentRemoteID
            )
            _ = upsertGraphRemoteFolders(accountID: account.id, remoteFolders: [created])
            office365SyncStatus = "Created folder “\(created.displayName)”"
            office365LastError = nil
            return folders.first { $0.accountID == account.id && $0.remoteID == created.id }
        } catch {
            let detail = error.localizedDescription
            office365LastError = detail
            office365SyncStatus = "Create folder failed — \(String(detail.prefix(160)))"
            if Self.isSilentAuthFailure(error) {
                office365NeedsSetup = true
            }
            return nil
        }
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

        // Local Sent preview always uses the plain `--` form once (HTML logo is send-only).
        let bodyWithSig = MailSignatureFormatting.appendPlainIfNeeded(
            body: draft.body,
            signature: live?.signature
        )
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
        ensureApproveMailbox()
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
            if let account = accountForApproveDraft(draft) {
                messages[i].accountID = account.id
                messages[i].fromName = account.name
                messages[i].fromAddress = account.email
                messages[i].deliveredTo = account.email
            }
            persistMessageCache()
        } else {
            guard let account = accountForApproveDraft(draft) else { return }
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
            persistMessageCache()
        }
    }

    /// Prefer the compose From / accountID so Callie's drafts stay From Callie (and send with her token).
    private func accountForApproveDraft(_ draft: ComposeDraft) -> MailAccount? {
        if let account = account(for: draft.accountID) {
            return account
        }
        let from = draft.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !from.isEmpty, let byFrom = accounts.first(where: { $0.email.lowercased() == from }) {
            return byFrom
        }
        if from.contains("calliope") || draft.fromAddress.lowercased().contains("calliope") {
            if let callie = accounts.first(where: { $0.isCalliope || $0.email.lowercased().contains("calliope") }) {
                return callie
            }
            return ensureOffice365Account(email: MSALAppConfig.calliopeEmail)
        }
        return accounts.first(where: { !$0.isCalliope }) ?? accounts.first
    }

    /// Shared smart Approve mailbox (ladder) — always present after seed; recreate if stripped.
    func ensureApproveMailbox() {
        if folders.contains(where: { $0.kind == .approve }) { return }
        folders.insert(
            MailFolder(id: approveFolderID, accountID: nil, name: "Approve", kind: .approve, sortOrder: -2, isPinned: true, isSmart: true),
            at: 0
        )
    }

    private static let injectApproveTestDefaultsKey = "rapSoDee.injectApproveTestDraft"
    private static let injectApproveTestSubject = "Approve-flow test (please send)"

    /// One-shot: `--inject-approve-test` launch arg or UserDefaults flag parks a Callie→Derek draft in Approve (not sent).
    func injectApproveTestDraftIfNeeded() {
        let viaArg = CommandLine.arguments.contains("--inject-approve-test")
        let viaDefaults = UserDefaults.standard.bool(forKey: Self.injectApproveTestDefaultsKey)
        guard viaArg || viaDefaults else { return }
        UserDefaults.standard.set(false, forKey: Self.injectApproveTestDefaultsKey)

        ensureApproveMailbox()
        _ = ensureOffice365Account(email: MSALAppConfig.calliopeEmail)
        guard let callie = accounts.first(where: {
            $0.isCalliope || $0.email.lowercased() == MSALAppConfig.calliopeEmail.lowercased()
        }) else {
            print("RapSoDee: inject Approve test draft skipped — Callie account missing")
            return
        }

        if messages.contains(where: {
            $0.subject == Self.injectApproveTestSubject && $0.disposition == .pendingApproval
        }) {
            print("RapSoDee: Approve test draft already present — not duplicating")
            return
        }

        let body = """
        Short note — draft from Callie for Derek to approve in RapSoDee Approve mailbox.

        Open Approve, review, then Approve & Send (or Reject). This was not auto-sent.
        """
        let draft = ComposeDraft(
            mode: .new,
            fromAddress: callie.email,
            to: "derek.brown@kaleyeahinspections.com",
            cc: "",
            subject: Self.injectApproveTestSubject,
            body: body,
            accountID: callie.id
        )
        saveApproveDraft(draft, messageID: nil)
        print("RapSoDee: injected Approve test draft From \(callie.email) → derek.brown@kaleyeahinspections.com")
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
        let inbox = MailFolder(accountID: id, name: "Inbox", kind: .inbox, sortOrder: base, isPinned: true, remoteID: "inbox")
        let sent = MailFolder(accountID: id, name: "Sent Items", kind: .sent, sortOrder: base + 1, remoteID: "sentitems")
        let drafts = MailFolder(accountID: id, name: "Drafts", kind: .drafts, sortOrder: base + 2, remoteID: "drafts")
        let archive = MailFolder(accountID: id, name: "Archive", kind: .archive, sortOrder: base + 3, remoteID: "archive")
        let trash = MailFolder(accountID: id, name: "Deleted Items", kind: .trash, sortOrder: base + 4, remoteID: "deleteditems")
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
        gmailSyncStatus = "Listing Gmail labels…"
        let previousIDs = Set(messages.filter { $0.accountID == account.id }.map(\.id))
        do {
            // Phase 1: LIST + upsert so the ladder shows labels immediately.
            let listed = try await GmailSyncService.listFolders(email: account.email, password: password)
            let labelTargets = upsertIMAPRemoteFolders(accountID: account.id, remoteFolders: listed)
            if !labelTargets.isEmpty {
                gmailSyncStatus = "Syncing Gmail… (\(labelTargets.count) labels)"
                persistMessageCache()
            } else {
                gmailSyncStatus = "Syncing Gmail…"
            }
            // Prefer extras already on the ladder so message hydrate binds to sidebar UUIDs.
            let extras = gmailExtraSyncTargets(accountID: account.id)
            let (fetched, remoteFolders, result) = try await GmailSyncService.sync(
                email: account.email,
                password: password,
                accountID: account.id,
                folderIDs: folderIDs,
                extraFolders: extras
            )
            // Refresh ladder in case LIST during sync saw anything new.
            _ = upsertIMAPRemoteFolders(accountID: account.id, remoteFolders: remoteFolders)
            // Incremental UID sync must not mark folders prunable (empty change set ≠ wipe).
            let synced: Set<UUID> = result.allowsFolderReplace
                ? Set([folderIDs.inbox, folderIDs.sent, folderIDs.drafts] + labelTargets.map(\.folderID))
                : []
            let newOnes = upsertSyncedMessages(
                accountID: account.id,
                syncedFolderIDs: synced,
                fetched: fetched,
                previousIDs: previousIDs,
                removedRemoteIDs: []
            )
            let labelNote = labelTargets.isEmpty ? "" : " · \(labelTargets.count) labels"
            gmailSyncStatus = result.status + labelNote
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
        let hasOffice = msalSignedIn
            || !MSALAppConfig.rememberedSignedInEmails.isEmpty
            || !office365Accounts().isEmpty
        guard hasGmail || hasOffice else { return }

        syncAllInFlight = true
        isUniversalSyncing = true
        defer {
            syncAllInFlight = false
            isUniversalSyncing = false
            enforceCalliopeExcludedFromUnifiedInbox()
        }
        if hasGmail {
            await syncGmailNow()
        }
        if hasOffice {
            await syncOffice365Now() // syncs every live Microsoft 365 mailbox
        }
    }

    func bootstrapLiveAccountsOnLaunch() async {
        office365IsSyncing = false
        office365SyncStartedAt = nil
        deduplicateMessagesByRemoteID()
        restoreGmailAccountShellIfNeeded()
        restoreOffice365AccountShellIfNeeded()
        enforceCalliopeExcludedFromUnifiedInbox()
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
        if msalSignedIn || !MSALAppConfig.rememberedSignedInEmails.isEmpty || !Office365SyncService.rememberedAccounts().isEmpty {
            restoreOffice365AccountShellIfNeeded()
            office365NeedsSetup = office365Accounts().isEmpty
            await syncOffice365Now()
        } else {
            office365NeedsSetup = true
            if office365SyncStatus.isEmpty {
                office365SyncStatus = "Optional: Add Microsoft 365 in Settings → Accounts."
            }
            persistOffice365SyncProbe(office365SyncStatus)
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
        let kinds: [(FolderKind, String, Int, Bool, String)] = [
            (.inbox, "Inbox", baseSort, true, "inbox"),
            (.sent, "Sent Items", baseSort + 1, false, "sentitems"),
            (.drafts, "Drafts", baseSort + 2, false, "drafts"),
            (.archive, "Archive", baseSort + 3, false, "archive"),
            (.trash, "Deleted Items", baseSort + 4, false, "deleteditems"),
        ]
        for (kind, name, order, pinned, remote) in kinds {
            if let idx = folders.firstIndex(where: { $0.accountID == accountID && $0.kind == kind }) {
                // Keep existing UUID; ensure Graph well-known remote id is stamped for import.
                if folders[idx].remoteID == nil || folders[idx].remoteID?.isEmpty == true {
                    folders[idx].remoteID = remote
                }
                // Prefer Outlook-style names once we know this is M365.
                if kind == .sent, folders[idx].name == "Sent" {
                    folders[idx].name = "Sent Items"
                }
                if kind == .trash, folders[idx].name == "Trash" {
                    folders[idx].name = "Deleted Items"
                }
                continue
            }
            folders.append(
                MailFolder(
                    accountID: accountID,
                    name: name,
                    kind: kind,
                    sortOrder: order,
                    isPinned: pinned,
                    remoteID: remote
                )
            )
        }
    }

    /// Named destinations for the EML import picker (Inbox / Sent Items / Archive / Drafts / customs).
    func office365EMLImportOptions() -> [EMLImportFolderOption] {
        guard let account = office365Account() else {
            return [
                EMLImportFolderOption(id: "inbox", title: "Inbox", graphFolderID: "inbox", isCustom: false),
                EMLImportFolderOption(id: "sentitems", title: "Sent Items", graphFolderID: "sentitems", isCustom: false),
                EMLImportFolderOption(id: "archive", title: "Archive", graphFolderID: "archive", isCustom: false),
                EMLImportFolderOption(id: "drafts", title: "Drafts", graphFolderID: "drafts", isCustom: false),
            ]
        }
        ensureStandardMailFolders(for: account.id, baseSort: -20)
        var options: [EMLImportFolderOption] = []
        var seen = Set<String>()
        let preferred: [(FolderKind, String, String)] = [
            (.inbox, "Inbox", "inbox"),
            (.sent, "Sent Items", "sentitems"),
            (.archive, "Archive", "archive"),
            (.drafts, "Drafts", "drafts"),
        ]
        for (kind, title, well) in preferred {
            if let folder = folders.first(where: { $0.accountID == account.id && $0.kind == kind }) {
                let gid = (folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? well
                if seen.insert(gid).inserted {
                    options.append(EMLImportFolderOption(id: gid, title: title, graphFolderID: gid, isCustom: false))
                }
            } else if seen.insert(well).inserted {
                options.append(EMLImportFolderOption(id: well, title: title, graphFolderID: well, isCustom: false))
            }
        }
        let customs = folders
            .filter { $0.accountID == account.id && $0.kind == .custom }
            .sorted { $0.sortOrder < $1.sortOrder || ($0.sortOrder == $1.sortOrder && $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }
        for folder in customs {
            guard let rid = folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty else { continue }
            if seen.insert(rid).inserted {
                options.append(
                    EMLImportFolderOption(
                        id: rid,
                        title: displayName(for: folder),
                        graphFolderID: rid,
                        isCustom: true
                    )
                )
            }
        }
        return options
    }

    /// Upsert Graph folder tree into the ladder. Well-known map by kind; customs by remoteID.
    @discardableResult
    func upsertGraphRemoteFolders(
        accountID: UUID,
        remoteFolders: [MicrosoftGraphMailService.GraphRemoteFolder]
    ) -> [(localFolderID: UUID, graphFolderID: String)] {
        ensureStandardMailFolders(for: accountID, baseSort: -20)
        var remoteIDToLocal: [String: UUID] = [:]
        for folder in folders where folder.accountID == accountID {
            if let rid = folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty {
                remoteIDToLocal[rid] = folder.id
            }
        }

        // First pass: stamp well-known remote IDs from Graph rows.
        for remote in remoteFolders {
            let kind = MicrosoftGraphMailService.folderKind(forDisplayName: remote.displayName)
            if let kind, let idx = folders.firstIndex(where: { $0.accountID == accountID && $0.kind == kind }) {
                folders[idx].remoteID = remote.id
                remoteIDToLocal[remote.id] = folders[idx].id
                // Keep ladder labels aligned with Outlook names when Graph provides them.
                if kind == .sent || kind == .trash || kind == .junk {
                    folders[idx].name = remote.displayName
                }
            }
        }

        // Second pass: customs (and any non-well-known).
        let baseSort = (folders.filter { $0.accountID == accountID }.map(\.sortOrder).max() ?? -20) + 1
        var nextSort = baseSort
        var messageSyncTargets: [(localFolderID: UUID, graphFolderID: String)] = []
        let recentImportIDs = Set(Self.recentImportGraphFolderIDs())

        for remote in remoteFolders {
            if MicrosoftGraphMailService.folderKind(forDisplayName: remote.displayName) != nil {
                continue
            }
            let rid = remote.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rid.isEmpty else { continue }
            let parentLocal: UUID? = {
                guard let pid = remote.parentFolderId?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else { return nil }
                return remoteIDToLocal[pid]
            }()
            if let idx = folders.firstIndex(where: { $0.accountID == accountID && $0.remoteID == rid }) {
                folders[idx].name = remote.displayName
                folders[idx].parentFolderID = parentLocal
                remoteIDToLocal[rid] = folders[idx].id
                if recentImportIDs.contains(rid) || remote.totalItemCount > 0 {
                    messageSyncTargets.append((folders[idx].id, rid))
                }
                continue
            }
            let local = MailFolder(
                accountID: accountID,
                name: remote.displayName,
                kind: .custom,
                sortOrder: nextSort,
                isPinned: false,
                remoteID: rid,
                parentFolderID: parentLocal
            )
            nextSort += 1
            folders.append(local)
            remoteIDToLocal[rid] = local.id
            if recentImportIDs.contains(rid) || remote.totalItemCount > 0 {
                messageSyncTargets.append((local.id, rid))
            }
        }

        // Cap custom message sync so Sync stays inside the hard timeout.
        return Array(messageSyncTargets.prefix(8))
    }


    /// Extra Gmail IMAP mailboxes already on the ladder (Starred / Important / user labels).
    private func gmailExtraSyncTargets(accountID: UUID) -> [(mailbox: String, folderID: UUID)] {
        folders.compactMap { folder -> (String, UUID)? in
            guard folder.accountID == accountID else { return nil }
            guard folder.kind == .custom else { return nil }
            guard let rid = folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty else { return nil }
            // Skip Graph-style well-known stubs accidentally left on a Gmail shell.
            let lower = rid.lowercased()
            if ["inbox", "sentitems", "archive", "drafts", "deleteditems", "junkemail"].contains(lower) {
                return nil
            }
            return (rid, folder.id)
        }
    }

    /// Upsert Gmail / IMAP LIST results into the ladder. Well-known map by kind; labels by mailbox remoteID.
    /// Returns message-sync targets for Starred / Important / user labels (All Mail excluded).
    @discardableResult
    func upsertIMAPRemoteFolders(
        accountID: UUID,
        remoteFolders: [IMAPFolderInfo]
    ) -> [(folderID: UUID, mailbox: String)] {
        ensureStandardMailFolders(for: accountID, baseSort: -10)
        var syncTargets: [(folderID: UUID, mailbox: String)] = []

        // Stamp well-known IMAP mailbox names onto standard rows (Gmail: `[Gmail]/Sent Mail`, …).
        for info in remoteFolders where info.isSelectable {
            let kind = info.kind
            guard kind != .custom else { continue }
            if let idx = folders.firstIndex(where: { $0.accountID == accountID && $0.kind == kind }) {
                folders[idx].remoteID = info.name
                // Prefer friendly Gmail names on the ladder (Sent / Trash / Drafts).
                if kind == .sent || kind == .trash || kind == .drafts {
                    let nice = info.ladderName
                    if !nice.isEmpty { folders[idx].name = nice }
                }
            }
            // Spam stays optional / out of the account card (ladder filters `.junk`).
        }

        let usefulSystemLeaves: Set<String> = ["STARRED", "IMPORTANT"]
        var nextSort = (folders.filter { $0.accountID == accountID }.map(\.sortOrder).max() ?? -10) + 1

        for info in remoteFolders {
            guard info.isSelectable, !info.isGmailAllMail else { continue }

            let leaf = info.ladderName.uppercased()
            let isUsefulSystem = info.isGmailSystemMailbox && usefulSystemLeaves.contains(leaf)
            let isUserLabel = !info.isGmailSystemMailbox && info.kind == .custom
            guard isUsefulSystem || isUserLabel else { continue }

            let rid = info.name
            let stableID = IMAPAccountSyncService.stableFolderID(accountID: accountID, mailbox: rid)

            if let idx = folders.firstIndex(where: { $0.accountID == accountID && $0.remoteID == rid }) {
                folders[idx].name = info.ladderName
                syncTargets.append((folders[idx].id, rid))
                continue
            }
            // Prefer stable id so first-sync message rows bind even before this upsert runs.
            if let idx = folders.firstIndex(where: { $0.id == stableID }) {
                folders[idx].name = info.ladderName
                folders[idx].remoteID = rid
                folders[idx].accountID = accountID
                syncTargets.append((folders[idx].id, rid))
                continue
            }

            let local = MailFolder(
                id: stableID,
                accountID: accountID,
                name: info.ladderName,
                kind: .custom,
                sortOrder: nextSort,
                isPinned: false,
                remoteID: rid
            )
            nextSort += 1
            folders.append(local)
            syncTargets.append((local.id, rid))
        }

        return syncTargets
    }

    private static let recentImportKey = "rapSoDee.office365.recentImportFolderIDs"

    private static func recentImportGraphFolderIDs() -> [String] {
        (UserDefaults.standard.stringArray(forKey: recentImportKey) ?? []).filter { !$0.isEmpty }
    }

    private static func rememberImportGraphFolderID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Skip pure well-known — those always sync.
        let wellKnown: Set<String> = ["inbox", "sentitems", "archive", "drafts", "deleteditems", "junkemail"]
        if wellKnown.contains(trimmed.lowercased()) { return }
        var list = recentImportGraphFolderIDs().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: recentImportKey)
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
                signature: account.signature,
                signatureLogoPath: account.signatureLogoPath
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

    func office365Accounts() -> [MailAccount] {
        accounts.filter { $0.isLiveOffice365 }
    }

    /// Primary / first live Microsoft 365 account (back-compat). Prefer `office365Account(email:)`.
    func office365Account() -> MailAccount? {
        office365Accounts().first
    }

    func office365Account(email: String) -> MailAccount? {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accounts.first { $0.isLiveOffice365 && $0.email.lowercased() == lower }
    }


    /// Re-read MSAL/device-code cache and publish so Settings shows Sign in vs Sync per mailbox.
    func noteOffice365AuthStateChanged() {
        MSALAuthService.shared.refreshSignedInStateFromCache()
        office365AuthRevision += 1
    }

    /// Observable per-mailbox auth — never treat "any M365 signed in" as this email being signed in.
    func isOffice365SignedIn(email: String) -> Bool {
        _ = office365AuthRevision
        return MSALAuthService.shared.isSignedIn(email: email)
    }

    func restoreOffice365AccountShellIfNeeded() {
        var planned: [RememberedOffice365Account] = Office365SyncService.rememberedAccounts()
        // Known live mailboxes + anything MSAL/device-code still has tokens for.
        var candidateEmails = MSALAppConfig.rememberedSignedInEmails
        candidateEmails.append(contentsOf: [
            Office365Defaults.defaultEmail,
            MSALAppConfig.calliopeEmail,
        ])
        for email in MSALAuthService.shared.signedInUsernames {
            candidateEmails.append(email)
        }
        for email in Self.uniqueEmailList(candidateEmails) {
            let lower = email.lowercased()
            if !planned.contains(where: { $0.email.lowercased() == lower }) {
                planned.append(RememberedOffice365Account(email: email, id: UUID()))
            }
        }
        // Always keep Derek + Callie mailbox rows visible (re-auth must not hide controls).
        for alwaysEmail in [Office365Defaults.defaultEmail, MSALAppConfig.calliopeEmail] {
            let lower = alwaysEmail.lowercased()
            if !planned.contains(where: { $0.email.lowercased() == lower }) {
                planned.append(RememberedOffice365Account(email: alwaysEmail, id: UUID()))
            }
        }
        guard !planned.isEmpty else {
            deduplicateLiveAccountShells()
            return
        }
        for remembered in planned {
            _ = ensureOffice365Account(email: remembered.email, id: remembered.id)
        }
        deduplicateLiveAccountShells()
    }

    private static func uniqueEmailList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { out.append(trimmed) }
        }
        return out
    }

    /// Collapse duplicate live shells (same provider + email) so One Inbox / ladder show each once.
    func deduplicateLiveAccountShells() {
        var keepByKey: [String: UUID] = [:]
        var removeIDs: [UUID] = []
        for account in accounts.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let provider: String
            if account.isLiveGmail {
                provider = "gmail"
            } else if account.isLiveOffice365 {
                provider = "m365"
            } else {
                continue
            }
            let key = provider + "|" + account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let keep = keepByKey[key] {
                if keep != account.id {
                    removeIDs.append(account.id)
                    // Re-home folders/messages onto the kept shell.
                    for i in folders.indices where folders[i].accountID == account.id {
                        folders[i].accountID = keep
                    }
                    for i in messages.indices where messages[i].accountID == account.id {
                        messages[i].accountID = keep
                    }
                }
            } else {
                keepByKey[key] = account.id
            }
        }
        if !removeIDs.isEmpty {
            let removeSet = Set(removeIDs)
            accounts.removeAll { removeSet.contains($0.id) }
            // Drop folders that collided onto an identical remoteID under the kept account.
            var seenFolder = Set<String>()
            folders = folders.filter { folder in
                guard let aid = folder.accountID else { return true }
                let remote = folder.remoteID ?? folder.id.uuidString
                let key = aid.uuidString + "|" + remote
                if seenFolder.contains(key) { return false }
                seenFolder.insert(key)
                return true
            }
            for (idx, _) in accounts.enumerated() {
                accounts[idx].sortOrder = idx
            }
        }
        enforceCalliopeExcludedFromUnifiedInbox()
    }

    private static func isCalliopeEmail(_ email: String) -> Bool {
        email.lowercased().contains("calliope")
    }

    @discardableResult
    func ensureOffice365Account(email: String, id: UUID = UUID()) -> MailAccount {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isCallie = Self.isCalliopeEmail(trimmed)

        // Match by email so adding Callie never overwrites Derek's shell.
        if let existing = accounts.first(where: { $0.isLiveOffice365 && $0.email.lowercased() == lower }) {
            if let i = accounts.firstIndex(where: { $0.id == existing.id }) {
                accounts[i].email = trimmed
                accounts[i].isCalliope = isCallie || accounts[i].isCalliope
                if accounts[i].isCalliopeMailbox {
                    accounts[i].isCalliope = true
                    accounts[i].includeInUnifiedInbox = false
                }
                if let override = MailDisplayNames.accountName(for: existing.id) {
                    accounts[i].name = override
                } else if accounts[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || accounts[i].name == "Microsoft 365" {
                    accounts[i].name = isCallie ? "Calliope" : "Microsoft 365"
                }
                if accounts[i].tintHex.isEmpty {
                    accounts[i].tintHex = isCallie ? Office365Defaults.calliopeTintHex : Office365Defaults.tintHex
                }
            }
            ensureStandardMailFolders(for: existing.id, baseSort: isCallie ? -15 : -20)
            if isCallie {
                ensureApproveMailbox()
                if !folders.contains(where: { $0.accountID == existing.id && $0.kind == .approve }) {
                    folders.append(
                        MailFolder(
                            accountID: existing.id,
                            name: "Approve",
                            kind: .approve,
                            sortOrder: (isCallie ? -15 : -20) + 5,
                            isPinned: false,
                            isSmart: false
                        )
                    )
                }
            }
            Office365SyncService.rememberAccount(email: trimmed, id: existing.id)
            return accounts.first { $0.id == existing.id }!
        }

        // Reuse stable id from persistence when present.
        let stableID = Office365SyncService.rememberedAccounts()
            .first(where: { $0.email.lowercased() == lower })?.id ?? id

        let account = MailAccount(
            id: stableID,
            name: isCallie ? "Calliope" : "Microsoft 365",
            email: trimmed,
            tintHex: isCallie ? Office365Defaults.calliopeTintHex : Office365Defaults.tintHex,
            signature: isCallie
                ? "Calliope Voss\nKale Yeah Inspections"
                : "Derek Brown\nKale Yeah Inspections",
            includeInUnifiedInbox: !isCallie,
            isCalliope: isCallie,
            sortOrder: -1,
            inboxPinned: true,
            isLiveGmail: false,
            isLiveOffice365: true
        )
        if let gmailIdx = accounts.firstIndex(where: { $0.isLiveGmail }) {
            accounts.insert(account, at: gmailIdx + 1)
        } else if let lastM365 = accounts.lastIndex(where: { $0.isLiveOffice365 }) {
            accounts.insert(account, at: lastM365 + 1)
        } else {
            accounts.insert(account, at: 0)
        }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        let base = isCallie ? -15 : -20
        let inbox = MailFolder(accountID: stableID, name: "Inbox", kind: .inbox, sortOrder: base, isPinned: true, remoteID: "inbox")
        let sent = MailFolder(accountID: stableID, name: "Sent Items", kind: .sent, sortOrder: base + 1, remoteID: "sentitems")
        let drafts = MailFolder(accountID: stableID, name: "Drafts", kind: .drafts, sortOrder: base + 2, remoteID: "drafts")
        let archive = MailFolder(accountID: stableID, name: "Archive", kind: .archive, sortOrder: base + 3, remoteID: "archive")
        let trash = MailFolder(accountID: stableID, name: "Deleted Items", kind: .trash, sortOrder: base + 4, remoteID: "deleteditems")
        var newFolders = [inbox, sent, drafts, archive, trash]
        // Callie's local Approve (hidden from per-account ladder; smart Approve aggregates kind == .approve).
        if isCallie {
            ensureApproveMailbox()
            newFolders.append(
                MailFolder(accountID: stableID, name: "Approve", kind: .approve, sortOrder: base + 5, isPinned: false, isSmart: false)
            )
        }
        folders.append(contentsOf: newFolders)
        Office365SyncService.rememberAccount(email: trimmed, id: stableID)
        applyPersistedDisplayNames()
        return accounts.first { $0.id == stableID } ?? account
    }

    func removeOffice365Account(accountID: UUID? = nil) {
        let targets: [MailAccount]
        if let accountID {
            targets = accounts.filter { $0.isLiveOffice365 && $0.id == accountID }
        } else {
            targets = office365Accounts()
        }
        guard !targets.isEmpty else {
            Task { @MainActor in await MSALAuthService.shared.signOut() }
            office365NeedsSetup = true
            return
        }
        for account in targets {
            KeychainCredentialStore.deletePassword(forEmail: account.email)
            Office365SyncService.forgetAccount(email: account.email)
            messages.removeAll { $0.accountID == account.id }
            folders.removeAll { $0.accountID == account.id }
            accounts.removeAll { $0.id == account.id }
            Task { @MainActor in
                await MSALAuthService.shared.signOut(email: account.email)
            }
        }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        office365NeedsSetup = office365Accounts().isEmpty
        office365SyncStatus = targets.count == 1
            ? "Signed out of \(targets[0].email)."
            : "Signed out of Microsoft 365."
        office365LastError = nil
    }

    /// Interactive MSAL sign-in, then Graph sync. Pass loginHint when adding a second mailbox (Callie).
    func signInMicrosoft365(
        clientIDOverride: String? = nil,
        tenantIDOverride: String? = nil,
        loginHint: String? = nil
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
        let hint = (loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Office365Defaults.defaultEmail
        let work = Task { @MainActor in
            await self.performSignInMicrosoft365(generation: generation, loginHint: hint)
        }
        office365InFlightTask = work
        await work.value
        if office365SyncGeneration == generation {
            office365InFlightTask = nil
        }
    }

    private func performSignInMicrosoft365(generation: Int, loginHint: String) async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Signing in \(loginHint)…"
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
                persistOffice365SyncProbe(office365SyncStatus)
            }
        }
        do {
            // Bound interactive sign-in so a hung ASWebAuthenticationSession cannot spin forever.
            // Prefer the token returned by sign-in (bound to the account just consented).
            let accessToken = try await withOffice365SyncTimeout(seconds: 90) {
                try await MSALAuthService.shared.signIn(loginHint: loginHint)
            }
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: accessToken)
            guard generation == office365SyncGeneration else { return }
            let stableID = Office365SyncService.rememberedAccounts()
                .first(where: { $0.email.lowercased() == email.lowercased() })?.id ?? UUID()
            _ = ensureOffice365Account(email: email, id: stableID)
            deduplicateLiveAccountShells()
            noteOffice365AuthStateChanged()
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

    /// Device-code fallback (preferred for Add Microsoft 365…). Pass loginHint for Callie.
    func signInMicrosoft365WithDeviceCode(
        clientIDOverride: String? = nil,
        tenantIDOverride: String? = nil,
        loginHint: String? = nil,
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
        let hint = (loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Office365Defaults.defaultEmail
        let work = Task { @MainActor in
            await self.performSignInMicrosoft365WithDeviceCode(generation: generation, loginHint: hint, onPrompt: onPrompt)
        }
        office365InFlightTask = work
        await work.value
        if office365SyncGeneration == generation {
            office365InFlightTask = nil
        }
    }

    private func performSignInMicrosoft365WithDeviceCode(
        generation: Int,
        loginHint: String,
        onPrompt: @MainActor @escaping (MSALDeviceCodePrompt) -> Void
    ) async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Starting device code for \(loginHint)…"
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
            }
        }
        do {
            // Use the device-code access token itself — do not re-acquire via MSAL cache,
            // which previously returned Derek's token when Callie had no MSAL account yet.
            let accessToken = try await MSALAuthService.shared.signInWithDeviceCode(
                loginHint: loginHint,
                onPrompt: onPrompt
            )
            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { return }
            let email = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: accessToken)
            guard generation == office365SyncGeneration else { return }
            let hintLower = loginHint.lowercased()
            let emailLower = email.lowercased()
            if !hintLower.isEmpty, hintLower != emailLower {
                office365LastError = "Device code signed in as \(email), but the hint was \(loginHint). Sign out of the other Microsoft session in the browser and try again for \(loginHint)."
                office365SyncStatus = "Signed in as \(email) (hint was \(loginHint))"
            } else {
                office365SyncStatus = "Signed in as \(email) (device code)"
            }
            let stableID = Office365SyncService.rememberedAccounts()
                .first(where: { $0.email.lowercased() == emailLower })?.id ?? UUID()
            _ = ensureOffice365Account(email: email, id: stableID)
            deduplicateLiveAccountShells()
            noteOffice365AuthStateChanged()
            office365NeedsSetup = false
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
            noteOffice365AuthStateChanged()
        }
    }

    func signOutMicrosoft365(accountID: UUID? = nil) async {
        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365SyncStatus = "Signing out…"
        defer {
            office365IsSyncing = false
            office365SyncStartedAt = nil
        }
        let targets: [MailAccount]
        if let accountID {
            targets = accounts.filter { $0.isLiveOffice365 && $0.id == accountID }
        } else {
            targets = office365Accounts()
        }
        if targets.isEmpty {
            if accountID == nil {
                await MSALAuthService.shared.signOut()
                Office365SyncService.clearRememberedAccount()
            }
            office365NeedsSetup = office365Accounts().isEmpty
            office365SyncStatus = "Signed out of Microsoft 365."
            office365LastError = nil
            return
        }
        for account in targets {
            await MSALAuthService.shared.signOut(email: account.email)
            KeychainCredentialStore.deletePassword(forEmail: account.email)
            // Keep every M365 shell visible so Sign in… stays available for re-auth.
            Office365SyncService.rememberAccount(email: account.email, id: account.id)
            messages.removeAll { $0.accountID == account.id }
        }
        for (idx, _) in accounts.enumerated() {
            accounts[idx].sortOrder = idx
        }
        restoreOffice365AccountShellIfNeeded()
        noteOffice365AuthStateChanged()
        office365NeedsSetup = office365Accounts().isEmpty
        office365SyncStatus = targets.count == 1
            ? "Signed out of \(targets[0].email)."
            : "Signed out of Microsoft 365."
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


    private func persistOffice365SyncProbe(_ status: String) {
        UserDefaults.standard.set(status, forKey: "rapSoDee.office365.lastSyncStatus")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "rapSoDee.office365.lastSyncAt")
        UserDefaults.standard.synchronize()
        // Also write a plain file — UserDefaults may not flush to the container plist promptly.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("RapSoDeeMailCache/lastOffice365Sync.txt")
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(status)\n"
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }

    private func performOffice365Sync(generation: Int) async {
        restoreOffice365AccountShellIfNeeded()
        guard generation == office365SyncGeneration, !Task.isCancelled else { return }

        office365IsSyncing = true
        office365SyncStartedAt = Date()
        office365LastError = nil
        office365SyncStatus = "Syncing Microsoft 365 via Graph (headers only)…"
        persistOffice365SyncProbe(office365SyncStatus)
        defer {
            if generation == office365SyncGeneration {
                office365IsSyncing = false
                office365SyncStartedAt = nil
                persistOffice365SyncProbe(office365SyncStatus)
            }
        }

        // If no shells yet but MSAL has sessions, create shells from signed-in emails.
        if office365Accounts().isEmpty {
            do {
                for email in MSALAuthService.shared.signedInUsernames {
                    let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                        try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false, loginHint: email)
                    }
                    let resolved = try await MicrosoftGraphMailService.fetchSignedInEmail(accessToken: token)
                    _ = ensureOffice365Account(email: resolved)
                }
            } catch {
                // Fall through — per-account loop may still recover via remembered shells.
            }
        }

        let targets = office365Accounts()
        guard !targets.isEmpty else {
            office365NeedsSetup = true
            office365LastError = "Sign in to Microsoft 365 first"
            office365SyncStatus = "No Microsoft 365 accounts signed in"
            return
        }

        var statuses: [String] = []
        var lastError: String?
        for account in targets {
            guard generation == office365SyncGeneration, !Task.isCancelled else { return }
            office365SyncStatus = "Syncing \(account.email)…"
            persistOffice365SyncProbe(office365SyncStatus)
            do {
                let status = try await syncOneOffice365Account(account, generation: generation)
                statuses.append("\(account.email): \(status)")
            } catch is CancellationError {
                if generation == office365SyncGeneration {
                    office365SyncStatus = "Sync cancelled"
                }
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                if generation == office365SyncGeneration {
                    office365SyncStatus = "Sync cancelled"
                }
                return
            } catch let timeout as Office365SyncTimeoutError {
                guard generation == office365SyncGeneration else { return }
                switch timeout {
                case .timedOut(let seconds):
                    _ = MSALAuthService.cancelPendingAuth()
                    syncAllInFlight = false
                    isUniversalSyncing = false
                    if seconds <= Int(Self.office365TokenTimeoutSeconds) + 1 {
                        office365NeedsSetup = true
                        lastError = "Silent Microsoft token timed out for \(account.email). Use Sign in with device code."
                        statuses.append("\(account.email): sign-in expired")
                        noteOffice365AuthStateChanged()
                    } else {
                        lastError = "Sync timed out after \(seconds)s for \(account.email)."
                        statuses.append("\(account.email): timed out")
                    }
                case .foldersMissing:
                    office365NeedsSetup = true
                    lastError = "Microsoft 365 folders missing for \(account.email) — Sign out, then Sign in with device code."
                    statuses.append("\(account.email): folders missing")
                }
            } catch {
                guard generation == office365SyncGeneration else { return }
                if Self.isCancelLike(error) {
                    office365SyncStatus = "Sync cancelled"
                    return
                }
                let detail = error.localizedDescription
                lastError = detail
                let short = detail.count > 280 ? String(detail.prefix(277)) + "…" : detail
                statuses.append("\(account.email): failed — \(short)")
                let lower = detail.lowercased()
                if Self.isSilentAuthFailure(error) || lower.contains("folders missing") || lower.contains("client id") {
                    office365NeedsSetup = true
                    noteOffice365AuthStateChanged()
                }
            }
        }

        guard generation == office365SyncGeneration else { return }
        office365SyncStatus = statuses.joined(separator: " · ")
        persistOffice365SyncProbe(office365SyncStatus)
        office365LastError = lastError
        if lastError == nil {
            office365NeedsSetup = false
        }
    }

    /// Sync a single live Microsoft 365 mailbox using that account's token (never another mailbox's).
    @discardableResult
    private func syncOneOffice365Account(_ account: MailAccount, generation: Int) async throws -> String {
        do {
            struct SyncPayload: Sendable {
                var email: String
                var messages: [MailMessage]
                var status: String
                var prunableFolderIDs: Set<UUID>
                var removedRemoteIDs: [String]
                var accountID: UUID
                var accountEmailHint: String
                var previousIDs: Set<UUID>
            }

            // Hard overall deadline — auto-stops so Cancel is never required for a hung spinner.
            let payload: SyncPayload = try await withOffice365SyncTimeout(seconds: Self.office365SyncTimeoutSeconds) {
                try Task.checkCancellation()
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
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
                // Upsert folder names first so ladder/picker fill even if message list is partial.
                // Extra message sync targets = recently imported customs (capped inside upsert).
                var extraTargets: [(localFolderID: UUID, graphFolderID: String)] = []
                // List folders up-front when possible so SyncPayload can carry them; sync() also lists.
                let (fetched, result, prunable, remoteFolders, removedRemoteIDs) = try await MicrosoftGraphMailService.sync(
                    accessToken: token,
                    accountID: accountID,
                    folderIDs: folderIDs,
                    accountEmail: email,
                    extraMessageFolders: {
                        // Build extras from current ladder customs marked recent / non-empty after a prior upsert.
                        let recent = Set(Self.recentImportGraphFolderIDs())
                        return self.folders.compactMap { folder -> (UUID, String)? in
                            guard folder.accountID == accountID, folder.kind == .custom,
                                  let rid = folder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !rid.isEmpty, recent.contains(rid) else { return nil }
                            return (folder.id, rid)
                        }
                    }()
                )
                try Task.checkCancellation()
                guard generation == self.office365SyncGeneration else { throw CancellationError() }
                // Apply folder tree on the main actor before returning (we are already on MainActor).
                extraTargets = self.upsertGraphRemoteFolders(accountID: accountID, remoteFolders: remoteFolders)
                // If sync didn't already pull recent customs (first run), that's OK — next Sync will.
                _ = extraTargets
                return SyncPayload(
                    email: email,
                    messages: fetched,
                    status: result.status,
                    prunableFolderIDs: prunable,
                    removedRemoteIDs: removedRemoteIDs,
                    accountID: accountID,
                    accountEmailHint: accountEmailHint,
                    previousIDs: previousIDs
                )
            }

            try Task.checkCancellation()
            guard generation == office365SyncGeneration else { throw CancellationError() }
            if payload.email.lowercased() != payload.accountEmailHint.lowercased() {
                _ = ensureOffice365Account(email: payload.email, id: payload.accountID)
            }
            let newOnes = upsertSyncedMessages(
                accountID: payload.accountID,
                syncedFolderIDs: payload.prunableFolderIDs,
                fetched: payload.messages,
                previousIDs: payload.previousIDs,
                removedRemoteIDs: payload.removedRemoteIDs
            )
            for msg in newOnes.prefix(3) {
                applyNotificationPolicy(for: msg)
            }
            persistMessageCache()
            return payload.status
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
        /// When set (Settings picker), takes precedence over destination / customFolderID.
        graphFolderID: String? = nil,
        destinationTitle: String? = nil,
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
        let destLabel: String
        if let gid = graphFolderID?.trimmingCharacters(in: .whitespacesAndNewlines), !gid.isEmpty {
            folderID = gid
            let trimmedTitle = destinationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedTitle.isEmpty {
                destLabel = trimmedTitle
            } else if let optTitle = office365EMLImportOptions().first(where: { $0.graphFolderID == gid })?.title {
                destLabel = optTitle
            } else {
                destLabel = gid
            }
        } else if destination == .custom {
            let custom = (customFolderID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !custom.isEmpty else {
                office365LastError = "Enter a Graph mailFolder id for Custom destination."
                return
            }
            folderID = custom
            destLabel = destinationTitle ?? "Custom"
        } else {
            folderID = destination.wellKnownName ?? "inbox"
            destLabel = destinationTitle ?? destination.title
        }

        emlImportIsRunning = true
        emlImportProgress = .empty(total: files.count)
        office365LastError = nil
        office365SyncStatus = "Importing \(files.count) EML file(s) into \(destLabel)…"

        let work = Task { @MainActor in
            defer {
                self.emlImportIsRunning = false
                self.emlImportTask = nil
            }
            do {
                var token: String
                do {
                    let hint = self.office365Account()?.email ?? Office365Defaults.defaultEmail
                    token = try await MSALAuthService.shared.acquireAccessToken(
                        interactiveIfNeeded: false,
                        loginHint: hint
                    )
                } catch {
                    guard let onPrompt = onDeviceCodePrompt else { throw error }
                    let hint = self.office365Account()?.email ?? Office365Defaults.defaultEmail
                    self.office365SyncStatus = "Sign-in expired — starting device code for EML import…"
                    token = try await MSALAuthService.shared.signInWithDeviceCode(
                        loginHint: hint,
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

                Self.rememberImportGraphFolderID(folderID)

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

    /// Load full Graph body + real attachments when opening a Kale Yeah message.
    /// List/delta sync only stores `bodyPreview` and attachment stubs (`filename == "Attachment"`).
    /// Also fetches inline CID images (even when `hasAttachments` was false) and rewrites
    /// HTML `cid:` refs to local files beside AttachmentStore / body sidecars.
    func ensureOffice365BodyLoaded(messageID: UUID) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[idx]
        guard let account = account(for: message.accountID), account.isLiveOffice365 else { return }
        guard let remoteID = message.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty else { return }
        let needsBody = message.body.count <= max(message.snippet.count + 40, 200)
        let hasUnresolvedCID = MailInlineCID.htmlHasUnresolvedCID(message.body)
        let needsAttachmentBytes = message.attachments.contains { !$0.hasLocalContent }
        // Inline-only mail often has no list stubs (`hasAttachments == false`) but still has cid: in HTML.
        let needsAttachments = needsAttachmentBytes || hasUnresolvedCID
        guard needsBody || needsAttachments else { return }
        let generation = office365SyncGeneration
        do {
            let token = try await withOffice365SyncTimeout(seconds: Self.office365TokenTimeoutSeconds) {
                try await MSALAuthService.shared.acquireAccessToken(interactiveIfNeeded: false, loginHint: account.email)
            }
            guard generation == office365SyncGeneration else { return }
            if needsBody {
                let loaded = try await MicrosoftGraphMailService.fetchMessageBody(accessToken: token, graphMessageID: remoteID)
                guard generation == office365SyncGeneration else { return }
                guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
                messages[i].body = loaded.body
                messages[i].isHTML = loaded.isHTML
                MailMessageCache.saveLoadedBody(messageID: messageID, text: loaded.body, isHTML: loaded.isHTML)
            }
            // Re-check after body hydrate — preview may not have contained cid:.
            let bodyNow = messages.first(where: { $0.id == messageID })?.body ?? message.body
            let unresolvedAfterBody = MailInlineCID.htmlHasUnresolvedCID(bodyNow)
            let stillNeedsAtts = needsAttachmentBytes || unresolvedAfterBody
            if stillNeedsAtts {
                let atts = try await MicrosoftGraphMailService.fetchFileAttachments(
                    messageGraphID: remoteID,
                    accessToken: token,
                    mailMessageID: messageID,
                    includeBytes: true
                )
                guard generation == office365SyncGeneration else { return }
                guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
                if !atts.isEmpty {
                    messages[i].attachments = atts
                } else if messages[i].attachments.allSatisfy({ $0.filename == "Attachment" && !$0.hasLocalContent }) {
                    // Server reports no file attachments — clear stubs so the paperclip UI does not lie.
                    messages[i].attachments = []
                }
            }
            // Rewrite cid: → local relative filenames (HTMLMailWebView uses AttachmentStore baseURL).
            if let i = messages.firstIndex(where: { $0.id == messageID }),
               messages[i].isHTML,
               MailInlineCID.htmlHasUnresolvedCID(messages[i].body),
               !messages[i].attachments.isEmpty {
                let rewritten = MailInlineCID.rewriteHTML(messages[i].body, attachments: messages[i].attachments)
                if rewritten != messages[i].body {
                    messages[i].body = rewritten
                    MailMessageCache.saveLoadedBody(messageID: messageID, text: rewritten, isHTML: true)
                }
            }
            persistMessageCache()
        } catch {
            if !Self.isCancelLike(error) {
                NSLog("Office365 open-message hydrate failed: \(error.localizedDescription)")
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
            signature: account.signature,
            signatureLogoPath: account.signatureLogoPath
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
            signature: account.signature,
            signatureLogoPath: account.signatureLogoPath
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
    /// named flags, snooze, and already-loaded bodies. Prunes stale rows only in successfully
    /// *replaced* folders (hydrate), and never when `fetched` is empty. Delta removals apply via
    /// `removedRemoteIDs` without wiping the rest of the local index.
    @discardableResult
    private func upsertSyncedMessages(
        accountID: UUID,
        syncedFolderIDs: Set<UUID>,
        fetched: [MailMessage],
        previousIDs: Set<UUID>,
        removedRemoteIDs: [String] = []
    ) -> [MailMessage] {
        // Apply on a local copy and publish ONCE — intermediate removeAll/append under
        // @Observable was flashing the mailbox empty then refilling during Sync.
        var working = messages
        let beforeCount = working.count

        var byRemote: [String: Int] = [:]
        // Folder-scoped: Sent + Inbox self-sends share internetMessageId but are distinct.
        var byInternetFolder: [String: Int] = [:]
        for (idx, m) in working.enumerated() where m.accountID == accountID {
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
        // Delta / server removals — drop matching local rows without folder-wide prune.
        let removedSet = Set(removedRemoteIDs.compactMap { normalizedRemoteID($0) })
        if !removedSet.isEmpty {
            working.removeAll { m in
                guard m.accountID == accountID else { return false }
                guard let r = normalizedRemoteID(m.remoteID) else { return false }
                return removedSet.contains(r)
            }
            // Rebuild indices after removal.
            byRemote.removeAll(keepingCapacity: true)
            byInternetFolder.removeAll(keepingCapacity: true)
            for (idx, m) in working.enumerated() where m.accountID == accountID {
                if let r = normalizedRemoteID(m.remoteID) {
                    byRemote[r] = idx
                }
                if let i = normalizedInternetMessageId(m.internetMessageId) {
                    byInternetFolder["\(m.folderID.uuidString)|\(i)"] = idx
                }
            }
        }
        // Clear this account's tombstones once the server no longer returns them.
        // While they still appear, activeFetched keeps suppressing resurrection.
        // After clear, an undelete on the server can bring the message back on a later sync.
        if !fetched.isEmpty {
            let fetchedRemotes = Set(fetched.compactMap { normalizedRemoteID($0.remoteID) })
            let localRemotes = Set(working.compactMap { m -> String? in
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
                if let idx = working.firstIndex(where: {
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
            _ = internetKey

            if let idx = matchIndex, working.indices.contains(idx) {
                let local = working[idx]
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
                // Preserve lazy-loaded / fuller local body over list/delta preview snippets.
                if local.body.count > incoming.body.count + 40 {
                    incoming.body = local.body
                    incoming.isHTML = local.isHTML
                }
                if local.attachments.contains(where: { $0.hasLocalContent || ($0.byteSize > 0 && $0.filename != "Attachment") }),
                   incoming.attachments.allSatisfy({ $0.filename == "Attachment" && $0.byteSize == 0 }) {
                    incoming.attachments = local.attachments
                }
                working[idx] = incoming
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
                working.append(incoming)
                let idx = working.count - 1
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
            working.removeAll { m in
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

        // Drop stale copies only in folders intentionally *replaced* by a hydrate window.
        // Delta / UID incremental passes leave syncedFolderIDs empty. Never prune when
        // the fetch set is empty — an empty/error response must not wipe local mail.
        // Also never prune when local already had mail in those folders and this pass
        // would shrink the visible set to empty (merge-only safety).
        if !fetched.isEmpty, !syncedFolderIDs.isEmpty {
            let localInSyncedBefore = beforeCount > 0 && messages.contains {
                $0.accountID == accountID && syncedFolderIDs.contains($0.folderID)
            }
            // If we already showed mail for these folders, hydrate must MERGE not replace.
            if !localInSyncedBefore {
                let fetchedIDs = Set(fetched.map(\.id))
                working.removeAll { m in
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
        }

        // In-place dedupe on the working copy, then single publish.
        working = deduplicatedMessages(working, accountID: accountID)
        working.sort { $0.receivedAt > $1.receivedAt }

        #if DEBUG
        let liveFolderIDs = Set(folders.map(\.id))
        let visibleAfter = working.filter { liveFolderIDs.contains($0.folderID) }.count
        let visibleBefore = messages.filter { liveFolderIDs.contains($0.folderID) }.count
        if visibleBefore > 0 && visibleAfter == 0 && !fetched.isEmpty {
            assertionFailure("Sync apply must not wipe visible mail when fetch succeeded")
        }
        #endif

        messages = working
        return newOnes
    }

    /// Collapse duplicate rows that share remoteID, or internetMessageId within the same folder.
    /// Sent + Inbox self-sends share Message-ID but must remain distinct.
    /// Keeps the copy with local flag/snooze state when present, otherwise the newest.
    func deduplicateMessagesByRemoteID(accountID: UUID? = nil) {
        let keep = deduplicatedMessages(messages, accountID: accountID)
        if keep.count != messages.count {
            messages = keep
        }
    }

    /// Pure dedupe used by Sync apply so the mailbox can be updated in one @Observable publish.
    private func deduplicatedMessages(_ input: [MailMessage], accountID: UUID? = nil) -> [MailMessage] {
        var keep: [MailMessage] = []
        var chosenRemote: [String: Int] = [:]
        var chosenInternet: [String: Int] = [:]

        for msg in input {
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
        return keep
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
        let snapshot = MailMessageCache.loadSnapshot()
        // Restore stable folder UUIDs BEFORE installing messages so Unified Inbox / folder
        // filters resolve immediately (ephemeral shell folders would orphan every row).
        restoreCachedAccountFolders(snapshot.folders)
        let knownAccountIDs = Set(accounts.map(\.id))
        var usable = snapshot.messages.filter { knownAccountIDs.contains($0.accountID) }
        guard !usable.isEmpty else { return }
        let hadCachedFolders = snapshot.folders.contains { $0.accountID != nil }
        usable = rebindOrphanedMessageFolders(usable)
        if messages.isEmpty {
            messages = usable
        } else {
            let existing = Set(messages.map(\.id))
            messages.append(contentsOf: usable.filter { !existing.contains($0.id) })
            messages = rebindOrphanedMessageFolders(messages)
        }
        // Migrate older caches that lacked folders[] so the next relaunch keeps stable UUIDs.
        if !hadCachedFolders {
            persistMessageCache()
        }
        #if DEBUG
        let liveFolderIDs = Set(folders.map(\.id))
        let visible = messages.filter { liveFolderIDs.contains($0.folderID) }.count
        print("RapSoDee: restored \(usable.count) cached messages (\(visible) bound to live folders, \(snapshot.folders.count) cached folders)")
        assert(visible > 0 || usable.isEmpty, "Cached mail must bind to live folder UUIDs on launch")
        #endif
    }
    /// Replace ephemeral standard folders with cached UUIDs; keep customs by remoteID/id.
    private func restoreCachedAccountFolders(_ cached: [MailFolder]) {
        let knownAccountIDs = Set(accounts.map(\.id))
        let cachedAccountFolders = cached.filter { folder in
            guard let aid = folder.accountID else { return false }
            return knownAccountIDs.contains(aid)
        }
        guard !cachedAccountFolders.isEmpty else { return }

        for cachedFolder in cachedAccountFolders {
            guard let accountID = cachedFolder.accountID else { continue }
            if cachedFolder.kind != .custom {
                // Drop the ephemeral shell row of the same kind so the cached UUID wins.
                folders.removeAll { $0.accountID == accountID && $0.kind == cachedFolder.kind }
                folders.append(cachedFolder)
                continue
            }
            if folders.contains(where: { $0.id == cachedFolder.id }) {
                continue
            }
            if let rid = cachedFolder.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rid.isEmpty,
               folders.contains(where: { $0.accountID == accountID && $0.remoteID == rid }) {
                continue
            }
            folders.append(cachedFolder)
        }
    }

    /// Map message.folderID onto live ladder UUIDs when an older cache lacked folders[].
    private func rebindOrphanedMessageFolders(_ input: [MailMessage]) -> [MailMessage] {
        let liveIDs = Set(folders.map(\.id))
        let orphanCachedIDs = Set(input.map(\.folderID).filter { !liveIDs.contains($0) })
        guard !orphanCachedIDs.isEmpty else { return input }

        var remap: [UUID: UUID] = [:]
        for account in accounts {
            let accountMsgs = input.filter { $0.accountID == account.id }
            let orphans = Set(accountMsgs.map(\.folderID).filter { orphanCachedIDs.contains($0) })
            guard !orphans.isEmpty else { continue }
            guard let inbox = folders.first(where: { $0.accountID == account.id && $0.kind == .inbox })?.id,
                  let sent = folders.first(where: { $0.accountID == account.id && $0.kind == .sent })?.id,
                  let drafts = folders.first(where: { $0.accountID == account.id && $0.kind == .drafts })?.id
            else { continue }

            let accountEmail = normalizedMailboxEmail(account.email)
            for orphanID in orphans {
                let group = accountMsgs.filter { $0.folderID == orphanID }
                let draftN = group.filter(\.isDraft).count
                let sentN = group.filter {
                    !$0.isDraft && normalizedMailboxEmail($0.fromAddress) == accountEmail
                }.count
                let total = max(group.count, 1)
                if draftN * 2 >= total {
                    remap[orphanID] = drafts
                } else if sentN * 2 >= total {
                    remap[orphanID] = sent
                } else {
                    // Default Inbox — Sync corrects Sent/Archive via remoteID upsert.
                    remap[orphanID] = inbox
                }
            }
        }

        guard !remap.isEmpty else { return input }
        return input.map { msg in
            guard let dest = remap[msg.folderID] else { return msg }
            var copy = msg
            copy.folderID = dest
            return copy
        }
    }

    private func persistMessageCache() {
        let accountFolders = folders.filter { $0.accountID != nil }
        MailMessageCache.saveMessages(messages, folders: accountFolders)
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

