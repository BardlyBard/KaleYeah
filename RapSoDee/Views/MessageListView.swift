import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MessageListView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let selection: LadderSelection
    @Binding var selectedMessageID: MailMessage.ID?
    var onFile: (MailMessage) -> Void
    var onSnooze: (MailMessage) -> Void

    private var messages: [MailMessage] {
        store.messages(for: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            List(selection: $selectedMessageID) {
                ForEach(messages) { message in
                    MessageRowView(message: message)
                        .tag(message.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowWash(for: message))
                        .contextMenu {
                            Menu("Flag") {
                                FlagMenuContent(
                                    flags: store.flags,
                                    currentFlagID: message.flagID,
                                    isFlagged: message.isFlagged,
                                    onSelect: { store.setFlag(message.id, flagID: $0) },
                                    onClear: { store.setFlag(message.id, flagID: nil) }
                                )
                            }
                            Button("File…") { onFile(message) }
                            Button("Snooze…") { onSnooze(message) }
                            Button("Archive") { store.archive(message.id) }
                            Divider()
                            Button("Delete", role: .destructive) { store.deleteRecessed(message.id) }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            // Keep controls usable but never let leaf-green own row selection.
            .tint(MuseTheme.oatmeal)
            .background(DisableListSelectionHighlight())
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
            if let first = messages.first {
                selectedMessageID = first.id
            } else {
                selectedMessageID = nil
            }
        }
        .onAppear {
            if selectedMessageID == nil {
                selectedMessageID = messages.first?.id
            }
        }
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
        let isSelected = selectedMessageID == message.id

        // Flagged: soft flag wash; stronger when selected/focused.
        if message.isFlagged {
            let hex = flagHex(for: message)
            if isSelected {
                return MuseTheme.flagSelectionWash(hex, scheme: colorScheme)
            }
            return MuseTheme.flagWash(hex, scheme: colorScheme)
        }

        // Unflagged + selected/focused: clear light grey (never leaf-green).
        if isSelected {
            return MuseTheme.selectionGrey(scheme: colorScheme)
        }

        // Unflagged + not selected: white / paper — no grey or account tint wash.
        if message.disposition == .pendingApproval {
            return MuseTheme.approveSoft.opacity(0.45)
        }
        return Color.clear
    }
}

struct MessageRowView: View {
    @Environment(DemoMailStore.self) private var store
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : MuseTheme.leaf)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.fromName)
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
                    if !message.attachments.isEmpty {
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
