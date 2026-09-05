import SwiftUI
import AppKit
import PDFKit

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
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            if message.disposition == .pendingApproval {
                approveBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            if message.isHTML {
                HTMLMailWebView(
                    html: message.body,
                    baseURL: AttachmentStore.directory(forMessageID: message.id)
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if !message.paperclipAttachments.isEmpty {
                    ScrollView {
                        attachmentsSection
                            .padding(20)
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if !message.paperclipAttachments.isEmpty {
                            attachmentsSection
                        }
                    }
                    .padding(20)
                }
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
            Task { await store.ensureOffice365BodyLoaded(messageID: message.id) }
        }
        .onChange(of: message.id) { _, newID in
            store.markRead(newID, read: true)
            Task { await store.ensureOffice365BodyLoaded(messageID: newID) }
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreviewSheet(attachment: attachment)
                .preferredColorScheme(.light)
        }
        .alert("Blocked attachment type", isPresented: $showBlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Executable, JavaScript, and HTML attachments cannot be previewed in RapSoDee.")
        }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
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
            Text("Draft pending approval — edit freely, then Approve & Send or Reject.")
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
            ForEach(message.paperclipAttachments) { attachment in
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
                    if attachment.hasLocalContent {
                        Button("Save…") { saveAttachment(attachment) }
                            .buttonStyle(MuseCapsuleButtonStyle())
                        if !attachment.isBlockedType {
                            Button("Open") { openAttachment(attachment) }
                                .buttonStyle(MuseCapsuleButtonStyle())
                        }
                    }
                    Button(attachment.isPreviewable ? "Preview" : (attachment.isBlockedType ? "Blocked" : "No preview")) {
                        if attachment.isBlockedType {
                            showBlockedAlert = true
                        } else if attachment.isPreviewable {
                            previewAttachment = attachment
                        }
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    .disabled(!attachment.isPreviewable || !attachment.hasLocalContent)
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

    private func openAttachment(_ attachment: MailAttachment) {
        guard let path = attachment.localPath else { return }
        NSWorkspace.shared.open(AttachmentStore.fileURL(path: path))
    }

    private func saveAttachment(_ attachment: MailAttachment) {
        guard let path = attachment.localPath, let data = AttachmentStore.load(path: path) else {
            saveError = "Attachment content is not available locally."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            saveError = "Could not write the file."
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
            Group {
                if attachment.isBlockedType {
                    Text("This attachment type cannot be previewed.")
                        .foregroundStyle(.secondary)
                } else if let path = attachment.localPath {
                    let url = AttachmentStore.fileURL(path: path)
                    if attachment.mimeType.hasPrefix("image/"), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if attachment.mimeType == "application/pdf" || url.pathExtension.lowercased() == "pdf" {
                        PDFKitRepresentedView(url: url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("No preview available — use Open or Save.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Attachment content is not available.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 280)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct PDFKitRepresentedView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
