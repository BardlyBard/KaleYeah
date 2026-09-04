import SwiftUI

struct MailboxLadderView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: LadderSelection

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
    }

    // MARK: - Account card (one soft tinted blob per account)

    @ViewBuilder
    private func accountCard(_ account: MailAccount) -> some View {
        let folders = folders(for: account)
        let focused = isAccountFocused(account)
        let tint = Color(hex: account.tintHex)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                    }
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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

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
                        Text(folder.name)
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
            }
        }
        .padding(.bottom, 8)
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
