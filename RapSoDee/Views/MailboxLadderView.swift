import SwiftUI

struct MailboxLadderView: View {
    @Environment(DemoMailStore.self) private var store
    @Binding var selection: LadderSelection

    var body: some View {
        List(selection: $selection) {
            Section("Smart") {
                Label("Inbox", systemImage: "tray.full")
                    .tag(LadderSelection.unifiedInbox)
                Label {
                    Text("Approve")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(MuseTheme.approve)
                }
                .listRowBackground(MuseTheme.approveSoft.opacity(0.55))
                .tag(LadderSelection.approve)

                if let snoozed = store.folders.first(where: { $0.kind == .snoozed }) {
                    Label("Snoozed", systemImage: "moon.zzz")
                        .tag(LadderSelection.folder(snoozed.id))
                }
            }

            ForEach(store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder })) { account in
                Section {
                    ForEach(folders(for: account)) { folder in
                        Label(folder.name, systemImage: icon(for: folder.kind))
                            .tag(LadderSelection.folder(folder.id))
                            .listRowBackground(MuseTheme.accountTint(account.tintHex))
                    }
                } header: {
                    HStack {
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
                }
            }

            if let junk = store.folders.first(where: { $0.kind == .junk }) {
                Section("Later") {
                    Label("Junk", systemImage: "xmark.bin")
                        .tag(LadderSelection.folder(junk.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("RapSoDee")
        .safeAreaInset(edge: .bottom) {
            Text("Reorder accounts in Settings")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
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
