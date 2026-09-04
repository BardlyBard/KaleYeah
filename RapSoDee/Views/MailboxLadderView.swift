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

            ForEach(store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder })) { account in
                Section {
                    ForEach(folders(for: account)) { folder in
                        Label(folder.name, systemImage: icon(for: folder.kind))
                            .tag(LadderSelection.folder(folder.id))
                            .listRowBackground(
                                mailboxWash(
                                    for: .folder(folder.id),
                                    base: MuseTheme.accountTint(account.tintHex)
                                )
                            )
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: account.tintHex))
                            .frame(width: 8, height: 8)
                        Text(account.name)
                        if account.inboxPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(MuseTheme.leaf)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuseTheme.ink.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuseTheme.sage.opacity(0.7), in: Capsule())
                }
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
