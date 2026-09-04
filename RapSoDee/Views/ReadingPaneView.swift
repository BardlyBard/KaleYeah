import SwiftUI

struct ReadingPaneView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let message: MailMessage
    var onReply: () -> Void
    var onReplyAll: () -> Void
    var onForward: () -> Void
    var onApproveEdit: () -> Void

    @State private var previewAttachment: MailAttachment?
    @State private var showBlockedAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if message.disposition == .pendingApproval {
                        approveBanner
                    }
                    Text(message.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !message.attachments.isEmpty {
                        attachmentsSection
                    }
                }
                .padding(20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous)
                .fill(MuseTheme.paperFill(scheme: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MuseTheme.cornerCard, style: .continuous)
                .strokeBorder(MuseTheme.oatmeal.opacity(0.28), lineWidth: 1)
        )
        .padding(MuseTheme.paneInset)
        .background(MuseTheme.paneChrome(scheme: colorScheme))
        .onAppear {
            store.markRead(message.id, read: true)
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreviewSheet(attachment: attachment)
        }
        .alert("Blocked attachment type", isPresented: $showBlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Executable, JavaScript, and HTML attachments cannot be previewed in RapSoDee.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                actionButtons
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fromName)
                        .font(.headline)
                    Text(message.fromAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("via \(message.deliveredTo)")
                        .font(.caption2)
                        .foregroundStyle(MuseTheme.leaf)
                }
            }
            Text("To: \(message.toAddresses.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.ccAddresses.isEmpty {
                Text("Cc: \(message.ccAddresses.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: MuseTheme.cornerCard,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: MuseTheme.cornerCard,
                style: .continuous
            )
            .fill(headerFlagWash)
        )
    }

    private var headerFlagWash: Color {
        guard message.isFlagged else { return MuseTheme.sage.opacity(0.35) }
        let hex: String
        if let id = message.flagID, let flag = store.flags.first(where: { $0.id == id }) {
            hex = flag.colorHex
        } else if let first = store.flags.first {
            hex = first.colorHex
        } else {
            hex = "E07A3D"
        }
        return MuseTheme.flagHeaderWash(hex, scheme: colorScheme)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if message.disposition == .pendingApproval {
                Button("Edit") { onApproveEdit() }
                    .buttonStyle(MuseCapsuleButtonStyle())
                Button("Approve & Send") {
                    store.approveAndSend(message.id)
                }
                .buttonStyle(MuseCapsuleButtonStyle(prominent: true, tint: MuseTheme.approve))
                Button("Reject", role: .destructive) {
                    store.rejectApprove(message.id)
                }
                .buttonStyle(MuseCapsuleButtonStyle(tint: Color.red.opacity(0.85)))
            } else {
                Button("Reply", action: onReply)
                    .buttonStyle(MuseCapsuleButtonStyle())
                Button("Reply All", action: onReplyAll)
                    .buttonStyle(MuseCapsuleButtonStyle())
                Button("Forward", action: onForward)
                    .buttonStyle(MuseCapsuleButtonStyle())
                FlagToolbarMenu(
                    flags: store.flags,
                    currentFlagID: message.flagID,
                    isFlagged: message.isFlagged,
                    onSelect: { store.setFlag(message.id, flagID: $0) },
                    onClear: { store.setFlag(message.id, flagID: nil) }
                )
                Menu("More") {
                    Menu("Flag") {
                        FlagMenuContent(
                            flags: store.flags,
                            currentFlagID: message.flagID,
                            isFlagged: message.isFlagged,
                            onSelect: { store.setFlag(message.id, flagID: $0) },
                            onClear: { store.setFlag(message.id, flagID: nil) }
                        )
                    }
                    Button("Archive") { store.archive(message.id) }
                    if let suggest = store.suggestSmartFile(for: message) {
                        Button("Smart File → \(suggest.name)") {
                            store.file(message.id, into: suggest.id)
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { store.deleteRecessed(message.id) }
                }
            }
        }
    }

    private var approveBanner: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(MuseTheme.approve)
            Text("Calliope draft — edit freely, then Approve & Send or Reject.")
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(12)
        .background(MuseTheme.approveSoft, in: RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous))
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments")
                .font(.headline)
            ForEach(message.attachments) { attachment in
                HStack {
                    Image(systemName: attachment.isBlockedType ? "hand.raised.fill" : "paperclip")
                        .foregroundStyle(attachment.isBlockedType ? .red : MuseTheme.leaf)
                    VStack(alignment: .leading) {
                        Text(attachment.filename)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(attachment.isPreviewable ? "Preview" : (attachment.isBlockedType ? "Blocked" : "No preview")) {
                        if attachment.isBlockedType {
                            showBlockedAlert = true
                        } else if attachment.isPreviewable {
                            previewAttachment = attachment
                        }
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    .disabled(!attachment.isPreviewable)
                }
                .padding(10)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: MuseTheme.cornerSmall, style: .continuous)
                )
            }
            Text("Previews are never automatic — tap Preview for PDF/images only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct AttachmentPreviewSheet: View {
    let attachment: MailAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(attachment.filename)
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true))
            }
            if attachment.mimeType.hasPrefix("image/") {
                RoundedRectangle(cornerRadius: MuseTheme.cornerLarge, style: .continuous)
                    .fill(MuseTheme.sage)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(MuseTheme.leaf)
                            Text("Demo image preview")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 280)
            } else if attachment.mimeType == "application/pdf" {
                RoundedRectangle(cornerRadius: MuseTheme.cornerLarge, style: .continuous)
                    .fill(MuseTheme.paper)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.richtext")
                                .font(.largeTitle)
                                .foregroundStyle(MuseTheme.leaf)
                            Text("Demo PDF preview — Stage 1 stub")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 280)
            } else {
                Text("No preview available")
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
    }
}
