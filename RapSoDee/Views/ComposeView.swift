import SwiftUI

struct ComposeView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State var draft: ComposeDraft
    var isPopOut: Bool
    var onClose: (() -> Void)? = nil
    var onPopOut: ((ComposeDraft) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider().opacity(0.4)
            TextEditor(text: $draft.body)
                .font(.body)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous)
                        .fill(MuseTheme.paperFill(scheme: colorScheme))
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                if !isPopOut, let onPopOut {
                    Button("Pop Out") {
                        onPopOut(draft)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(MuseCapsuleButtonStyle())
                if isApproveEdit {
                    Button("Save to Approve") {
                        if case .editDraft(let message) = draft.mode {
                            store.saveApproveDraft(draft, messageID: message.id)
                        } else {
                            store.saveApproveDraft(draft, messageID: nil)
                        }
                        close()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    Button("Approve & Send") {
                        store.sendCompose(draft)
                        if case .editDraft(let message) = draft.mode {
                            store.removeMessage(message.id)
                        }
                        close()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true, tint: MuseTheme.approve))
                } else {
                    Button("Send") {
                        store.sendCompose(draft)
                        close()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true, tint: MuseTheme.leaf))
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: isPopOut ? 0 : MuseTheme.cornerCard, style: .continuous)
                .fill(MuseTheme.paperFill(scheme: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: isPopOut ? 0 : MuseTheme.cornerCard, style: .continuous))
        .padding(isPopOut ? 0 : MuseTheme.paneInset)
        .background(isPopOut ? Color.clear : MuseTheme.paneChrome(scheme: colorScheme))
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
        .scrollContentBackground(.hidden)
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
