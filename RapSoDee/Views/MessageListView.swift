import SwiftUI

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
                        .listRowBackground(rowBackground(for: message))
                        .contextMenu {
                            Button("Flag") { store.toggleFlag(message.id, flagID: store.flags.first?.id) }
                            Button("File…") { onFile(message) }
                            Button("Snooze…") { onSnooze(message) }
                            Button("Archive") { store.archive(message.id) }
                            Divider()
                            Button("Delete", role: .destructive) { store.deleteRecessed(message.id) }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func rowBackground(for message: MailMessage) -> Color {
        // Flag wash dominates over account tint / approve soft so flagged mail is obvious.
        if message.isFlagged {
            let hex: String
            if let id = message.flagID, let flag = store.flags.first(where: { $0.id == id }) {
                hex = flag.colorHex
            } else if let first = store.flags.first {
                hex = first.colorHex
            } else {
                hex = "E07A3D"
            }
            return MuseTheme.flagWash(hex, scheme: colorScheme)
        }
        if message.disposition == .pendingApproval {
            return MuseTheme.approveSoft.opacity(0.45)
        }
        if let account = store.account(for: message.accountID) {
            return MuseTheme.accountTint(account.tintHex)
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

            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.vertical, 4)
    }

    private var flagColor: Color {
        if let id = message.flagID, let flag = store.flags.first(where: { $0.id == id }) {
            return Color(hex: flag.colorHex)
        }
        return MuseTheme.approve
    }
}
