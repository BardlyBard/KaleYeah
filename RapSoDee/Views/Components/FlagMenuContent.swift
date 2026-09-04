import SwiftUI

/// Apple Mail–style flag chooser: color swatch + name per flag, plus Clear Flag.
struct FlagMenuContent: View {
    let flags: [MailFlag]
    var currentFlagID: UUID? = nil
    var isFlagged: Bool = false
    let onSelect: (UUID) -> Void
    let onClear: () -> Void

    var body: some View {
        ForEach(flags) { flag in
            Button {
                onSelect(flag.id)
            } label: {
                Label {
                    Text(flag.name)
                } icon: {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(Color(hex: flag.colorHex))
                }
            }
        }
        if !flags.isEmpty {
            Divider()
        }
        Button("Clear Flag", action: onClear)
            .disabled(!isFlagged)
    }
}

/// Toolbar / reading-pane control that presents the same menu.
struct FlagToolbarMenu: View {
    let flags: [MailFlag]
    var currentFlagID: UUID? = nil
    var isFlagged: Bool = false
    var isEnabled: Bool = true
    let onSelect: (UUID) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu {
            FlagMenuContent(
                flags: flags,
                currentFlagID: currentFlagID,
                isFlagged: isFlagged,
                onSelect: onSelect,
                onClear: onClear
            )
        } label: {
            Label("Flag", systemImage: isFlagged ? "flag.fill" : "flag")
        }
        .disabled(!isEnabled)
        .help("Flag")
    }
}
