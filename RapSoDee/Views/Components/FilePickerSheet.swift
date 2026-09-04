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
                    ForEach(store.folders.filter { $0.kind == .custom || $0.kind == .archive || $0.kind == .inbox }) { folder in
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
            .navigationTitle("File Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
