import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State var draft: ComposeDraft
    var isPopOut: Bool
    var onClose: (() -> Void)? = nil
    var onPopOut: ((ComposeDraft) -> Void)? = nil

    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            form
            if !draft.attachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
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
                .padding(.top, 10)
            if let logoPath = store.account(for: draft.accountID)?.signatureLogoPath,
               let data = AttachmentStore.load(path: logoPath),
               let image = NSImage(data: data) {
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 48)
                    Text("Signature logo (included on send)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
            Divider().opacity(0.4)
            if let sendError, !sendError.isEmpty {
                Text(sendError)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            } else if isSending {
                Text(store.outboundStatus.isEmpty ? "Sending…" : store.outboundStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(spacing: 10) {
                Button {
                    attachFiles()
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .buttonStyle(MuseCapsuleButtonStyle())
                .help("Attach files")
                .disabled(isSending)

                if !isPopOut, let onPopOut {
                    Button("Pop Out") {
                        onPopOut(draft)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    .disabled(isSending)
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    .disabled(isSending)
                if isApproveEdit {
                    Button("Save to Approve") {
                        saveToApprove()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    .disabled(isSending)
                    Button(isSending ? "Sending…" : "Approve & Send") {
                        performSend(removeApproveDraft: true)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true, tint: MuseTheme.approve))
                    .disabled(isSending || store.accounts.isEmpty)
                } else {
                    if isCallieFrom {
                        Button("Save to Approve") {
                            saveToApprove()
                        }
                        .buttonStyle(MuseCapsuleButtonStyle(tint: MuseTheme.approve))
                        .disabled(isSending || store.accounts.isEmpty)
                        .help("Park this draft in Approve for Derek — does not send")
                    }
                    Button(isSending ? "Sending…" : "Send") {
                        performSend(removeApproveDraft: false)
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true, tint: MuseTheme.leaf))
                    .disabled(isSending || store.accounts.isEmpty)
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


    /// One entry per mailbox email so the From picker never lists duplicates.
    private var composeFromAccounts: [MailAccount] {
        var seen = Set<String>()
        var out: [MailAccount] = []
        for account in store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let key = account.email.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(account)
        }
        return out
    }

    private func composeFromLabel(_ account: MailAccount) -> String {
        let who: String
        if account.isCalliope || account.email.lowercased().contains("calliope") {
            who = "Callie"
        } else if account.isLiveGmail {
            who = "Gmail"
        } else if account.isLiveOffice365 {
            who = account.name
        } else {
            who = account.name
        }
        return "\(who) — \(account.email)"
    }

    private var isApproveEdit: Bool {
        if case .editDraft(let m) = draft.mode { return m.disposition == .pendingApproval }
        return false
    }

    private var isCallieFrom: Bool {
        let from = draft.fromAddress.lowercased()
        if from.contains("calliope") { return true }
        if let account = store.account(for: draft.accountID) {
            return account.isCalliope || account.email.lowercased().contains("calliope")
        }
        return false
    }

    private func saveToApprove() {
        if case .editDraft(let message) = draft.mode {
            store.saveApproveDraft(draft, messageID: message.id)
        } else {
            store.saveApproveDraft(draft, messageID: nil)
        }
        close()
    }

    private var form: some View {
        Form {
            Picker("From (whose email)", selection: $draft.fromAddress) {
                ForEach(composeFromAccounts, id: \.id) { account in
                    Text(composeFromLabel(account)).tag(account.email)
                }
            }
            .onChange(of: draft.fromAddress) { oldValue, newValue in
                let oldAccount = store.accounts.first { $0.email.lowercased() == oldValue.lowercased() }
                if let account = store.accounts.first(where: { $0.email.lowercased() == newValue.lowercased() }) {
                    draft.accountID = account.id
                    draft.body = MailSignatureFormatting.replaceSignature(
                        in: draft.body,
                        old: oldAccount?.signature,
                        new: account.signature
                    )
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

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .foregroundStyle(MuseTheme.leaf)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.filename)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(att.byteSize), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            draft.attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Color.secondary.opacity(0.10),
                        in: Capsule()
                    )
                }
            }
        }
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        panel.message = "Choose files to attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let imported = try AttachmentStore.importUserFile(from: url)
                draft.attachments.append(
                    ComposeAttachment(
                        filename: imported.filename,
                        mimeType: imported.mimeType,
                        byteSize: imported.byteSize,
                        localPath: imported.path
                    )
                )
            } catch {
                // Skip unreadable files silently; no content logging.
            }
        }
    }

    private func performSend(removeApproveDraft: Bool) {
        sendError = nil
        isSending = true
        let snapshot = draft
        Task { @MainActor in
            let ok = await store.sendCompose(snapshot)
            isSending = false
            if ok {
                if removeApproveDraft, case .editDraft(let message) = snapshot.mode {
                    store.removeMessage(message.id)
                }
                close()
            } else {
                let status = store.outboundStatus
                let detail = store.office365LastError ?? store.gmailLastError
                if !status.isEmpty {
                    sendError = status
                } else if let detail, !detail.isEmpty {
                    sendError = detail
                } else {
                    sendError = "Send failed — see Settings for details"
                }
            }
        }
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
