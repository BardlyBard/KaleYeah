import SwiftUI

struct MailboxLadderView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: LadderSelection

    /// Per-account mailbox list expand state. Missing keys default to expanded.
    @State private var expandedByAccount: [UUID: Bool] = [:]
    @State private var renameAccountTarget: MailAccount?
    @State private var renameFolderTarget: MailFolder?
    @State private var newFolderAccount: MailAccount?
    @State private var renameText = ""
    @State private var newFolderBusy = false

    private static let expandDefaultsKey = "rapSoDee.accountMailboxExpanded"

    var body: some View {
        List(selection: $selection) {
            Section {
                ladderRow(
                    title: "Inbox",
                    systemImage: "tray.full",
                    tag: .unifiedInbox,
                    wash: Color.clear
                )
                Label {
                    Text("Approve")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(MuseTheme.approve)
                }
                .tag(LadderSelection.approve)
                .listRowBackground(mailboxWash(for: .approve, base: MuseTheme.approveSoft.opacity(0.55)))

                if let snoozed = store.folders.first(where: { $0.kind == .snoozed }) {
                    ladderRow(
                        title: "Snoozed",
                        systemImage: "moon.zzz",
                        tag: .folder(snoozed.id),
                        wash: Color.clear
                    )
                }
            } header: {
                softSectionHeader("Smart")
            }

            Section {
                ForEach(store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder })) { account in
                    accountCard(account)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled(true)
                }
            } header: {
                softSectionHeader("Accounts")
            }

            if let junk = store.folders.first(where: { $0.kind == .junk }) {
                Section {
                    ladderRow(
                        title: "Junk",
                        systemImage: "xmark.bin",
                        tag: .folder(junk.id),
                        wash: Color.clear
                    )
                } header: {
                    softSectionHeader("Later")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(MuseTheme.paneChrome(scheme: colorScheme))
        .tint(MuseTheme.leaf)
        .navigationTitle("RapSoDee")
        .safeAreaInset(edge: .bottom) {
            Text("Reorder accounts in Settings")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(MuseTheme.sage.opacity(0.55), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .onAppear {
            loadExpandedState()
            expandAccountsContainingSelection()
        }
        .onChange(of: selection) { _, _ in
            expandAccountsContainingSelection()
        }
        .sheet(item: $renameAccountTarget) { account in
            RenameSheet(
                title: "Rename account",
                prompt: "Display name",
                text: $renameText
            ) {
                store.renameAccount(accountID: account.id, name: renameText)
                renameAccountTarget = nil
            } onCancel: {
                renameAccountTarget = nil
            }
            .preferredColorScheme(.light)
        }
        .sheet(item: $renameFolderTarget) { folder in
            RenameSheet(
                title: "Rename mailbox",
                prompt: "Display label",
                text: $renameText
            ) {
                store.renameFolder(folderID: folder.id, name: renameText)
                renameFolderTarget = nil
            } onCancel: {
                renameFolderTarget = nil
            }
            .preferredColorScheme(.light)
        }
        .sheet(item: $newFolderAccount) { account in
            RenameSheet(
                title: "New Folder",
                prompt: "Folder name",
                text: $renameText
            ) {
                let name = renameText
                newFolderBusy = true
                Task { @MainActor in
                    defer {
                        newFolderBusy = false
                        newFolderAccount = nil
                    }
                    _ = await store.createOffice365Folder(displayName: name)
                }
            } onCancel: {
                newFolderAccount = nil
            }
            .preferredColorScheme(.light)
            .disabled(newFolderBusy)
        }
    }

    // MARK: - Account card (one soft tinted blob per account)

    @ViewBuilder
    private func accountCard(_ account: MailAccount) -> some View {
        let folders = folders(for: account)
        let focused = isAccountFocused(account)
        let tint = Color(hex: account.tintHex)
        let expanded = isExpanded(account)

        VStack(alignment: .leading, spacing: 2) {
            Button {
                toggleExpanded(account)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MuseTheme.ink.opacity(0.55))
                        .frame(width: 12, alignment: .center)
                        .contentTransition(.symbolEffect(.replace))

                    Circle()
                        .fill(tint)
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(account.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MuseTheme.ink)
                                .lineLimit(1)
                            if account.inboxPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(MuseTheme.leaf)
                                    .help("Pinned into One Inbox")
                            }
                        }
                        Text(account.email)
                            .font(.caption2)
                            .foregroundStyle(MuseTheme.ink.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, expanded ? 6 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse mailboxes" : "Expand mailboxes")
            .contextMenu {
                Button("Rename Account…") {
                    renameText = account.name
                    renameAccountTarget = account
                }
                if account.isLiveOffice365 {
                    Button("New Folder…") {
                        renameText = ""
                        newFolderAccount = account
                    }
                }
            }

            if expanded {
                ForEach(folders) { folder in
                    let tag = LadderSelection.folder(folder.id)
                    let selected = selection == tag
                    Button {
                        selection = tag
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: folder.kind))
                                .font(.body)
                                .foregroundStyle(selected ? MuseTheme.leaf : MuseTheme.ink.opacity(0.72))
                                .frame(width: 18)
                            Text(store.displayName(for: folder))
                                .font(.body)
                                .fontWeight(selected ? .semibold : .regular)
                                .foregroundStyle(MuseTheme.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: MuseTheme.cornerSmall, style: .continuous)
                                    .fill(MuseTheme.sage.opacity(colorScheme == .dark ? 0.55 : 0.92))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: MuseTheme.cornerSmall, style: .continuous)
                                            .strokeBorder(MuseTheme.leaf.opacity(0.28), lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .contextMenu {
                        Button("Rename Mailbox…") {
                            renameText = store.displayName(for: folder)
                            renameFolderTarget = folder
                        }
                    }
                }
            }
        }
        .padding(.bottom, expanded ? 8 : 0)
        .background {
            RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous)
                .fill(MuseTheme.accountCardWash(account.tintHex, focused: focused, scheme: colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous)
                        .strokeBorder(
                            tint.opacity(focused ? 0.42 : 0.16),
                            lineWidth: focused ? 1.25 : 1
                        )
                }
                .shadow(
                    color: tint.opacity(focused ? 0.18 : 0.06),
                    radius: focused ? 8 : 3,
                    y: focused ? 2 : 1
                )
        }
        .animation(.easeInOut(duration: 0.18), value: focused)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - Expand / collapse persistence

    private func isExpanded(_ account: MailAccount) -> Bool {
        expandedByAccount[account.id] ?? true
    }

    private func toggleExpanded(_ account: MailAccount) {
        let next = !isExpanded(account)
        expandedByAccount[account.id] = next
        persistExpandedState()
    }

    private func setExpanded(_ accountID: UUID, _ expanded: Bool) {
        if expandedByAccount[accountID] == expanded { return }
        expandedByAccount[accountID] = expanded
        persistExpandedState()
    }

    private func expandAccountsContainingSelection() {
        switch selection {
        case .folder(let id):
            if let accountID = store.folders.first(where: { $0.id == id })?.accountID {
                setExpanded(accountID, true)
            }
        case .accountInbox(let accountID):
            setExpanded(accountID, true)
        case .unifiedInbox, .approve:
            break
        }
    }

    private func loadExpandedState() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.expandDefaultsKey) as? [String: Bool] else {
            return
        }
        var loaded: [UUID: Bool] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                loaded[id] = value
            }
        }
        if !loaded.isEmpty {
            expandedByAccount = loaded
        }
    }

    private func persistExpandedState() {
        let raw = Dictionary(uniqueKeysWithValues: expandedByAccount.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.expandDefaultsKey)
    }

    private func isAccountFocused(_ account: MailAccount) -> Bool {
        switch selection {
        case .folder(let id):
            return store.folders.first(where: { $0.id == id })?.accountID == account.id
        case .accountInbox(let accountID):
            return accountID == account.id
        case .unifiedInbox, .approve:
            return false
        }
    }

    // MARK: - Shared chrome

    @ViewBuilder
    private func softSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MuseTheme.ink.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MuseTheme.oatmeal.opacity(0.28), in: Capsule())
    }

    @ViewBuilder
    private func ladderRow(title: String, systemImage: String, tag: LadderSelection, wash: Color) -> some View {
        Label(title, systemImage: systemImage)
            .tag(tag)
            .listRowBackground(mailboxWash(for: tag, base: wash))
    }

    @ViewBuilder
    private func mailboxWash(for tag: LadderSelection, base: Color) -> some View {
        let selected = selection == tag
        RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous)
            .fill(selected ? MuseTheme.sage.opacity(colorScheme == .dark ? 0.55 : 0.95) : base)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous)
                        .strokeBorder(MuseTheme.leaf.opacity(0.28), lineWidth: 1)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }

    private func folders(for account: MailAccount) -> [MailFolder] {
        store.folders
            .filter { $0.accountID == account.id && $0.kind != .approve && $0.kind != .snoozed && $0.kind != .junk }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func icon(for kind: FolderKind) -> String {
        switch kind {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .snoozed: return "moon.zzz"
        case .approve: return "checkmark.seal"
        case .junk: return "xmark.bin"
        case .custom: return "folder"
        }
    }
}


private struct RenameSheet: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
