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
                description: Text("Choose a message from the list — inbox is your working set.")
            )
            .padding(MuseTheme.paneInset)
            .background(MuseTheme.paper.opacity(0.55))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                startCompose(.new)
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .help("New Message")

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
            let account = store.accounts.first { !$0.isCalliope } ?? store.accounts[0]
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
            let account = store.account(for: message.accountID) ?? store.accounts[0]
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
            let account = store.account(for: message.accountID) ?? store.accounts[0]
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
