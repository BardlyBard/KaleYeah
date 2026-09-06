import SwiftUI

struct FilePickerSheet: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let message: MailMessage
    var onPick: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let suggest = store.suggestSmartFile(for: message) {
                    Section("Smart File suggest") {
                        Button {
                            onPick(suggest.id)
                        } label: {
                            Label(suggest.name, systemImage: "sparkles")
                        }
                    }
                }
                Section("Folders") {
                    // Same-account only — never offer Kale/M365 folders for Gmail mail (or vice versa).
                    ForEach(store.folders.filter {
                        ($0.kind == .custom || $0.kind == .archive || $0.kind == .inbox)
                            && $0.accountID == message.accountID
                    }) { folder in
                        Button {
                            onPick(folder.id)
                        } label: {
                            HStack {
                                Text(folder.name)
                                Spacer()
                                if let account = folder.accountID.flatMap({ store.account(for: $0) }) {
                                    Text(account.name)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(MuseTheme.paper.opacity(0.55))
            .navigationTitle("File Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(MuseCapsuleButtonStyle())
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
