import SwiftUI

struct ComposeView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var draft: ComposeDraft
    var isPopOut: Bool
    var onClose: (() -> Void)? = nil
    var onPopOut: ((ComposeDraft) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            TextEditor(text: $draft.body)
                .font(.body)
                .padding(8)
            Divider()
            HStack {
                if !isPopOut, let onPopOut {
                    Button("Pop Out") {
                        onPopOut(draft)
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                if isApproveEdit {
                    Button("Save to Approve") {
                        if case .editDraft(let message) = draft.mode {
                            store.saveApproveDraft(draft, messageID: message.id)
                        } else {
                            store.saveApproveDraft(draft, messageID: nil)
                        }
                        close()
                    }
                    Button("Approve & Send") {
                        store.sendCompose(draft)
                        if case .editDraft(let message) = draft.mode {
                            store.removeMessage(message.id)
                        }
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuseTheme.approve)
                } else {
                    Button("Send") {
                        store.sendCompose(draft)
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuseTheme.leaf)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: draft) { _, newValue in
            if isPopOut {
                ComposeSession.shared.update(newValue)
            }
        }
    }

    private var isApproveEdit: Bool {
        if case .editDraft(let m) = draft.mode { return m.disposition == .pendingApproval }
        return false
    }

    private var form: some View {
        Form {
            Picker("From", selection: $draft.fromAddress) {
                ForEach(store.accounts) { account in
                    Text("\(account.name) <\(account.email)>").tag(account.email)
                }
            }
            .onChange(of: draft.fromAddress) { _, newValue in
                if let account = store.accounts.first(where: { $0.email == newValue }) {
                    draft.accountID = account.id
                }
            }
            TextField("To", text: $draft.to)
            TextField("Cc", text: $draft.cc)
            TextField("Subject", text: $draft.subject)
        }
        .formStyle(.grouped)
        .frame(maxHeight: 200)
    }

    private func close() {
        if isPopOut {
            ComposeSession.shared.remove(draft.id)
            dismiss()
        } else {
            onClose?()
        }
    }
}
