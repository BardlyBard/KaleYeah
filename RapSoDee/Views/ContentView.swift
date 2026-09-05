import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext

    @State private var selection: LadderSelection = .unifiedInbox
    @State private var selectedMessageID: MailMessage.ID?
    @State private var inlineCompose: ComposeDraft?
    @State private var showSettings = false
    @State private var fileTarget: MailMessage?
    @State private var snoozeTarget: MailMessage?
    @State private var didHydrate = false
    @State private var dismissGmailPrompt = UserDefaults.standard.bool(forKey: GmailDefaults.promptDismissedKey)

    private var visibleMessages: [MailMessage] {
        store.messages(for: selection)
    }

    private var selectedMessage: MailMessage? {
        visibleMessages.first { $0.id == selectedMessageID } ?? store.messages.first { $0.id == selectedMessageID }
    }

    var body: some View {
        NavigationSplitView {
            MailboxLadderView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            MessageListView(
                selection: selection,
                selectedMessageID: $selectedMessageID,
                onFile: { fileTarget = $0 },
                onSnooze: { snoozeTarget = $0 }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
        } detail: {
            detailPane
        }
        .searchable(text: Bindable(store).searchText, placement: .toolbar, prompt: "Search from, subject, snippet")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(store)
                .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(item: $fileTarget) { message in
            FilePickerSheet(message: message) { folderID in
                store.file(message.id, into: folderID)
                fileTarget = nil
            }
            .environment(store)
        }
        .sheet(item: $snoozeTarget) { message in
            SnoozeSheet { date in
                store.snooze(message.id, until: date)
                snoozeTarget = nil
            }
        }
        .onAppear {
            hydrateFlagsIfNeeded()
            // Demo removal can leave a stale folder UUID selected — snap back to Unified Inbox.
            if !store.isValidSelection(selection) {
                selection = .unifiedInbox
            }
            Task {
                await store.bootstrapLiveAccountsOnLaunch()
                if !store.isValidSelection(selection) {
                    selection = .unifiedInbox
                }
                // Accounts present but still no mail after bootstrap — force one more sync pass.
                if !store.accounts.isEmpty && store.messages.isEmpty {
                    await store.syncAllConnectedAccounts()
                }
            }
        }
        .onChange(of: store.folders.count) { _, _ in
            if !store.isValidSelection(selection) {
                selection = .unifiedInbox
            }
        }
        .task {
            // Auto-sync every 5 minutes while the window is open; skip if a sync is already running.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { break }
                await store.syncAllConnectedAccounts()
            }
        }
        .overlay(alignment: .top) {
            if !store.outboundStatus.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: store.outboundIsError ? "exclamationmark.triangle.fill" : "paperplane.fill")
                        .foregroundStyle(store.outboundIsError ? Color.orange : MuseTheme.leaf)
                    Text(store.outboundStatus)
                        .font(.caption.weight(store.outboundIsError ? .semibold : .regular))
                        .foregroundStyle(store.outboundIsError ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    if store.outboundIsError {
                        Button("Settings") { showSettings = true }
                            .buttonStyle(.bordered)
                        Button("Dismiss") {
                            store.outboundStatus = ""
                            store.outboundIsError = false
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .top) {
            if store.gmailNeedsSetup && !dismissGmailPrompt {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(MuseTheme.leaf)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Gmail")
                            .font(.headline)
                        Text("Paste a Google App Password in Settings → Accounts for \(GmailDefaults.defaultEmail).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings") { showSettings = true }
                        .buttonStyle(MuseCapsuleButtonStyle(prominent: true))
                    Button("Later") {
                        dismissGmailPrompt = true
                        UserDefaults.standard.set(true, forKey: GmailDefaults.promptDismissedKey)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous))
                .padding(12)
            }
        }
        .focusedSceneValue(\.rapActions, RapActions(
            archive: { archiveSelected() },
            flag: { flagSelected() },
            file: { if let m = selectedMessage { fileTarget = m } },
            snooze: { if let m = selectedMessage { snoozeTarget = m } },
            next: { moveSelection(1) },
            prev: { moveSelection(-1) }
        ))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let inlineCompose {
            ComposeView(draft: inlineCompose, isPopOut: false) {
                self.inlineCompose = nil
            } onPopOut: { draft in
                var d = draft
                d.popOut = true
                ComposeSession.shared.register(d)
                self.inlineCompose = nil
                openWindow(id: "compose", value: d.id)
            }
        } else if let message = selectedMessage {
            ReadingPaneView(
                message: message,
                onReply: { startCompose(.reply(message)) },
                onReplyAll: { startCompose(.replyAll(message)) },
                onForward: { startCompose(.forward(message)) },
                onApproveEdit: {
                    startCompose(.editDraft(message))
                }
            )
        } else {
            ContentUnavailableView(
                "Pick a leaf",
                systemImage: "envelope.open",
                description: Text(store.accounts.isEmpty ? "Connect Gmail or Microsoft 365 in Settings to get started." : "Choose a message from the list — inbox is your working set.")
            )
            .padding(MuseTheme.paneInset)
            .background(MuseTheme.paper.opacity(0.55))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await store.syncAllConnectedAccounts() }
            } label: {
                if store.isAnyLiveSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help("Sync Gmail and Microsoft 365")
            .disabled(store.isAnyLiveSyncing)

            Button {
                startCompose(.new)
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .help("New Message")
            .disabled(store.accounts.isEmpty)

            FlagToolbarMenu(
                flags: store.flags,
                currentFlagID: selectedMessage?.flagID,
                isFlagged: selectedMessage?.isFlagged ?? false,
                isEnabled: selectedMessage != nil,
                onSelect: { flagID in
                    guard let id = selectedMessageID else { return }
                    store.setFlag(id, flagID: flagID)
                },
                onClear: {
                    guard let id = selectedMessageID else { return }
                    store.setFlag(id, flagID: nil)
                }
            )

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func startCompose(_ mode: ComposeMode) {
        let draft = makeDraft(mode)
        inlineCompose = draft
    }

    private func makeDraft(_ mode: ComposeMode) -> ComposeDraft {
        switch mode {
        case .new:
            guard let account = store.gmailAccount()
                ?? store.office365Account()
                ?? store.accounts.first(where: { !$0.isCalliope })
                ?? store.accounts.first else {
                return ComposeDraft(
                    mode: .new,
                    fromAddress: "",
                    to: "",
                    cc: "",
                    subject: "",
                    body: "",
                    accountID: UUID()
                )
            }
            let sig = account.signature.isEmpty ? "" : "\n\n--\n\(account.signature)"
            return ComposeDraft(
                mode: .new,
                fromAddress: account.email,
                to: "",
                cc: "",
                subject: "",
                body: sig,
                accountID: account.id
            )
        case .reply(let message):
            let account = store.account(for: message.accountID) ?? store.accounts.first!
            let from = message.deliveredTo
            let sig = account.signature.isEmpty ? "" : "\n\n--\n\(account.signature)"
            return ComposeDraft(
                mode: mode,
                fromAddress: from,
                to: message.fromAddress,
                cc: "",
                subject: subjectByPrefixing(message.subject, "Re:"),
                body: "\n\nOn \(message.receivedAt.formatted()), \(message.fromName) wrote:\n> "
                    + message.body.replacingOccurrences(of: "\n", with: "\n> ")
                    + sig,
                accountID: accountForDelivery(from) ?? message.accountID
            )
        case .replyAll(let message):
            let account = store.account(for: message.accountID) ?? store.accounts.first!
            let from = message.deliveredTo
            var recipients = ([message.fromAddress] + message.toAddresses + message.ccAddresses)
                .filter { $0.lowercased() != from.lowercased() }
            recipients = Array(Set(recipients)).sorted()
            let sig = account.signature.isEmpty ? "" : "\n\n--\n\(account.signature)"
            return ComposeDraft(
                mode: mode,
                fromAddress: from,
                to: recipients.joined(separator: ", "),
                cc: "",
                subject: subjectByPrefixing(message.subject, "Re:"),
                body: "\n\nOn \(message.receivedAt.formatted()), \(message.fromName) wrote:\n> "
                    + message.body.replacingOccurrences(of: "\n", with: "\n> ")
                    + sig,
                accountID: accountForDelivery(from) ?? message.accountID
            )
        case .forward(let message):
            let from = message.deliveredTo
            return ComposeDraft(
                mode: mode,
                fromAddress: from,
                to: "",
                cc: "",
                subject: subjectByPrefixing(message.subject, "Fwd:"),
                body: "\n\n---------- Forwarded message ----------\n" + message.body,
                accountID: accountForDelivery(from) ?? message.accountID
            )
        case .editDraft(let message):
            return ComposeDraft(
                mode: mode,
                fromAddress: message.fromAddress,
                to: message.toAddresses.joined(separator: ", "),
                cc: message.ccAddresses.joined(separator: ", "),
                subject: message.subject,
                body: message.body,
                accountID: message.accountID
            )
        }
    }

    private func accountForDelivery(_ address: String) -> UUID? {
        store.accounts.first { $0.email.lowercased() == address.lowercased() }?.id
    }

    private func subjectByPrefixing(_ subject: String, _ prefix: String) -> String {
        if subject.lowercased().hasPrefix(prefix.lowercased()) { return subject }
        return "\(prefix) \(subject)"
    }

    private func archiveSelected() {
        guard let id = selectedMessageID else { return }
        store.archive(id)
        moveSelection(1)
    }

    private func flagSelected() {
        guard let id = selectedMessageID else { return }
        store.flagShortcut(id)
    }

    private func moveSelection(_ delta: Int) {
        let list = visibleMessages
        guard !list.isEmpty else { return }
        if let id = selectedMessageID, let idx = list.firstIndex(where: { $0.id == id }) {
            let next = min(max(0, idx + delta), list.count - 1)
            selectedMessageID = list[next].id
        } else {
            selectedMessageID = list[0].id
        }
    }

    private func hydrateFlagsIfNeeded() {
        guard !didHydrate else { return }
        didHydrate = true
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedFlag>())) ?? []
        // Upgrade sparse/legacy seeds so Derek always sees a full color chooser.
        let needsDefaults = existing.isEmpty || existing.count < MailFlag.defaults.count
        if needsDefaults {
            for row in existing { modelContext.delete(row) }
            if store.flags.count < MailFlag.defaults.count {
                store.flags = MailFlag.defaults
            }
            store.lastUsedFlagID = store.flags.first?.id
            for (i, flag) in store.flags.enumerated() {
                modelContext.insert(PersistedFlag(id: flag.id, name: flag.name, colorHex: flag.colorHex, sortOrder: i))
            }
            try? modelContext.save()
        } else {
            store.flags = existing
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { MailFlag(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
            store.lastUsedFlagID = store.flags.first?.id
        }
    }
}

struct RapActions {
    var archive: () -> Void
    var flag: () -> Void
    var file: () -> Void
    var snooze: () -> Void
    var next: () -> Void
    var prev: () -> Void
}

private struct RapActionsKey: FocusedValueKey {
    typealias Value = RapActions
}

extension FocusedValues {
    var rapActions: RapActions? {
        get { self[RapActionsKey.self] }
        set { self[RapActionsKey.self] = newValue }
    }
}
