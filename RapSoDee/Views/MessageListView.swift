import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MessageListView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(MailDragController.self) private var mailDrag
    @Environment(\.colorScheme) private var colorScheme
    let selection: LadderSelection
    /// Focused message for the reading pane (last interacted / primary).
    @Binding var selectedMessageID: MailMessage.ID?
    /// Multi-select set — Cmd-click / Shift-click on macOS List, plus row checkboxes.
    @Binding var selectedMessageIDs: Set<MailMessage.ID>
    var onFile: (MailMessage) -> Void
    var onFileMany: ([MailMessage]) -> Void
    var onSnooze: (MailMessage) -> Void

    private var messages: [MailMessage] {
        store.messages(for: selection)
    }

    private var selectedMessages: [MailMessage] {
        messages.filter { selectedMessageIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if selectedMessageIDs.count > 1 {
                bulkActionBar
            }
            List(selection: $selectedMessageIDs) {
                ForEach(messages) { message in
                    MessageRowView(
                        message: message,
                        isChecked: selectedMessageIDs.contains(message.id),
                        onToggleCheck: { toggleCheck(message.id) }
                    )
                        .tag(message.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowWash(for: message))
                        .draggable(dragPayload(for: message)) {
                            dragPreview(for: message)
                        }
                        .contextMenu {
                            if selectedMessageIDs.count > 1, selectedMessageIDs.contains(message.id) {
                                bulkContextMenu
                            } else {
                                singleContextMenu(for: message)
                            }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .tint(MuseTheme.oatmeal)
            .background(DisableListSelectionHighlight())
            .environment(\.defaultMinListRowHeight, 1)
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
        .navigationTitle(title)
        .onChange(of: selection) { _, _ in
            selectedMessageIDs = []
            if let first = messages.first {
                selectedMessageID = first.id
                selectedMessageIDs = [first.id]
            } else {
                selectedMessageID = nil
            }
        }
        .onChange(of: selectedMessageIDs) { _, new in
            syncFocusedMessage(from: new)
        }
        .onAppear {
            if selectedMessageID == nil, let first = messages.first {
                selectedMessageID = first.id
                selectedMessageIDs = [first.id]
            } else if let id = selectedMessageID, selectedMessageIDs.isEmpty {
                selectedMessageIDs = [id]
            }
        }
    }

    private func syncFocusedMessage(from ids: Set<MailMessage.ID>) {
        if ids.isEmpty {
            selectedMessageID = nil
            return
        }
        if let id = selectedMessageID, ids.contains(id) { return }
        // Prefer visible order for a stable primary when Shift-selecting a range.
        if let firstVisible = messages.first(where: { ids.contains($0.id) }) {
            selectedMessageID = firstVisible.id
        } else {
            selectedMessageID = ids.first
        }
    }

    private func toggleCheck(_ id: MailMessage.ID) {
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
        } else {
            selectedMessageIDs.insert(id)
        }
        selectedMessageID = id
    }

    private var title: String {
        switch selection {
        case .unifiedInbox: return "Inbox"
        case .approve: return "Approve"
        case .folder(let id): return store.folder(for: id)?.name ?? "Mailbox"
        case .accountInbox: return "Inbox"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Sort", selection: Bindable(store).sort) {
                ForEach(MessageSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)

            Picker("Filter", selection: Bindable(store).filter) {
                ForEach(MessageFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            Spacer()
            Text("\(messages.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuseTheme.sage.opacity(0.8), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedMessageIDs.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuseTheme.ink.opacity(0.75))

            Button("Read") { bulkMarkRead(true) }
                .buttonStyle(MuseCapsuleButtonStyle())
            Button("Unread") { bulkMarkRead(false) }
                .buttonStyle(MuseCapsuleButtonStyle())

            Menu("Flag") {
                ForEach(store.flags) { flag in
                    Button(flag.name) {
                        for id in selectedMessageIDs {
                            store.setFlag(id, flagID: flag.id)
                        }
                    }
                }
                Divider()
                Button("Clear Flag") {
                    for id in selectedMessageIDs {
                        store.setFlag(id, flagID: nil)
                    }
                }
            }
            .buttonStyle(MuseCapsuleButtonStyle())

            Button("File…") { bulkFile() }
                .buttonStyle(MuseCapsuleButtonStyle())
                .disabled(!bulkFileEnabled)

            Button("Archive") { bulkArchive() }
                .buttonStyle(MuseCapsuleButtonStyle(prominent: true))

            Spacer(minLength: 0)

            Button("Clear") {
                if let id = selectedMessageID {
                    selectedMessageIDs = [id]
                } else {
                    selectedMessageIDs = []
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MuseTheme.oatmeal.opacity(0.45))
        .help(bulkFileEnabled ? "File selected mail into a same-account folder" : "Select mail from one account to file")
    }

    private var bulkFileEnabled: Bool {
        let accounts = Set(selectedMessages.map(\.accountID))
        return accounts.count == 1 && !selectedMessages.isEmpty
    }

    private func bulkMarkRead(_ read: Bool) {
        for id in selectedMessageIDs {
            store.markRead(id, read: read)
        }
    }

    private func bulkArchive() {
        for id in Array(selectedMessageIDs) {
            store.archive(id)
        }
        clearBulkSelectionAfterMutation()
    }

    private func bulkDelete() {
        for id in Array(selectedMessageIDs) {
            store.deleteRecessed(id)
        }
        clearBulkSelectionAfterMutation()
    }

    private func clearBulkSelectionAfterMutation() {
        selectedMessageIDs = []
        selectedMessageID = messages.first?.id
        if let id = selectedMessageID { selectedMessageIDs = [id] }
    }

    private func bulkFile() {
        let msgs = selectedMessages
        guard let first = msgs.first else { return }
        let account = first.accountID
        let same = msgs.filter { $0.accountID == account }
        guard same.count == msgs.count else { return }
        if same.count == 1 {
            onFile(same[0])
        } else {
            onFileMany(same)
        }
    }


    /// Build drag payload at drag-start (`draggable` autoclosure). Multi-select → entire same-account selection.
    private func dragPayload(for message: MailMessage) -> MailFileDragPayload {
        let ids: [UUID]
        if selectedMessageIDs.contains(message.id), selectedMessageIDs.count > 1 {
            let sameAccount = selectedMessages.filter { $0.accountID == message.accountID }.map(\.id)
            ids = sameAccount.isEmpty ? [message.id] : sameAccount
        } else {
            ids = [message.id]
        }
        mailDrag.begin(messageIDs: ids, accountID: message.accountID)
        return MailFileDragPayload(messageIDs: ids, accountID: message.accountID)
    }

    @ViewBuilder
    private func dragPreview(for message: MailMessage) -> some View {
        let count = mailDrag.messageIDs.isEmpty ? 1 : mailDrag.messageIDs.count
        HStack(spacing: 8) {
            Image(systemName: count > 1 ? "envelope.open.fill" : "envelope.fill")
                .foregroundStyle(MuseTheme.leaf)
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 1 ? "\(count) messages" : (message.subject.isEmpty ? "(No subject)" : message.subject))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if count == 1 {
                    Text(message.fromName.isEmpty ? message.fromAddress : message.fromName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MuseTheme.paper, in: RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous)
                .strokeBorder(MuseTheme.oatmeal.opacity(0.5), lineWidth: 1)
        }
        .frame(maxWidth: 240)
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func singleContextMenu(for message: MailMessage) -> some View {
        Menu("Flag") {
            FlagMenuContent(
                flags: store.flags,
                currentFlagID: message.flagID,
                isFlagged: message.isFlagged,
                onSelect: { store.setFlag(message.id, flagID: $0) },
                onClear: { store.setFlag(message.id, flagID: nil) }
            )
        }
        Button("Mark Read") { store.markRead(message.id, read: true) }
        Button("Mark Unread") { store.markRead(message.id, read: false) }
        Button("File…") { onFile(message) }
        Button("Snooze…") { onSnooze(message) }
        Button("Archive") { store.archive(message.id) }
        Divider()
        Button("Delete", role: .destructive) { store.deleteRecessed(message.id) }
    }

    @ViewBuilder
    private var bulkContextMenu: some View {
        Button("Mark Read") { bulkMarkRead(true) }
        Button("Mark Unread") { bulkMarkRead(false) }
        Menu("Flag") {
            ForEach(store.flags) { flag in
                Button(flag.name) {
                    for id in selectedMessageIDs { store.setFlag(id, flagID: flag.id) }
                }
            }
            Divider()
            Button("Clear Flag") {
                for id in selectedMessageIDs { store.setFlag(id, flagID: nil) }
            }
        }
        if bulkFileEnabled {
            Button("File…") { bulkFile() }
        }
        Button("Archive") { bulkArchive() }
        Divider()
        Button("Delete", role: .destructive) { bulkDelete() }
    }

    @ViewBuilder
    private func rowWash(for message: MailMessage) -> some View {
        let fill = rowBackground(for: message)
        RoundedRectangle(cornerRadius: MuseTheme.cornerMed, style: .continuous)
            .fill(fill)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }

    private func flagHex(for message: MailMessage) -> String {
        if let id = message.flagID, let flag = store.flags.first(where: { $0.id == id }) {
            return flag.colorHex
        }
        if let first = store.flags.first {
            return first.colorHex
        }
        return "E07A3D"
    }

    private func rowBackground(for message: MailMessage) -> Color {
        let isSelected = selectedMessageIDs.contains(message.id)

        if message.isFlagged {
            let hex = flagHex(for: message)
            if isSelected {
                return MuseTheme.flagSelectionWash(hex, scheme: colorScheme)
            }
            return MuseTheme.flagWash(hex, scheme: colorScheme)
        }

        if isSelected {
            return MuseTheme.selectionGrey(scheme: colorScheme)
        }

        if message.disposition == .pendingApproval {
            return MuseTheme.approveSoft.opacity(0.45)
        }
        return Color.clear
    }
}

struct MessageRowView: View {
    @Environment(DemoMailStore.self) private var store
    let message: MailMessage
    var isChecked: Bool = false
    var onToggleCheck: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggleCheck?()
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isChecked ? MuseTheme.leaf : MuseTheme.ink.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help(isChecked ? "Deselect" : "Select")

            Circle()
                .fill(message.isRead ? Color.clear : MuseTheme.leaf)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(primaryPartyLabel)
                        .font(.headline)
                        .fontWeight(message.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(message.receivedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(message.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(flagColor)
                            .font(.caption)
                    }
                    if !message.paperclipAttachments.isEmpty {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if message.disposition == .pendingApproval {
                        Text("Approve")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MuseTheme.approve.opacity(0.25), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var flagColor: Color {
        if let id = message.flagID, let flag = store.flags.first(where: { $0.id == id }) {
            return Color(hex: flag.colorHex)
        }
        return MuseTheme.approve
    }

    private var primaryPartyLabel: String {
        let inSent = store.folder(for: message.folderID)?.kind == .sent
        if inSent {
            return recipientListLabel
        }
        if !message.fromName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message.fromName
        }
        return message.fromAddress
    }

    private var recipientListLabel: String {
        let tos = message.toAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = tos.first else { return "(No recipient)" }
        if tos.count == 1 { return first }
        return "\(first) +\(tos.count - 1)"
    }
}

#if os(macOS)
/// Disables NSTableView’s accent-colored selection highlight so `listRowBackground` owns selection looks.
private struct DisableListSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let table = findTableView(startingAt: nsView) else { return }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
            if table.allowsMultipleSelection == false {
                table.allowsMultipleSelection = true
            }
        }
    }

    private func findTableView(startingAt view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let node = current {
            if let table = node as? NSTableView {
                return table
            }
            if let found = findTableView(in: node) {
                return found
            }
            current = node.superview
        }
        return nil
    }

    private func findTableView(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView { return table }
        for child in root.subviews {
            if let found = findTableView(in: child) { return found }
        }
        return nil
    }
}
#endif
