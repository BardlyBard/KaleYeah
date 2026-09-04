import SwiftUI
#if os(macOS)
import AppKit
#endif

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
                // Non-template NSImage swatch — Menu would otherwise recolor SF Symbols / shapes.
                Label {
                    Text(flag.name)
                } icon: {
                    Image(nsImage: FlagSwatch.circleImage(hex: flag.colorHex))
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

#if os(macOS)
/// Renders a filled circle that keeps its real color inside AppKit menus
/// (template SF Symbols get wiped to label/primary style).
enum FlagSwatch {
    static func circleImage(hex: String, side: CGFloat = 12) -> NSImage {
        let color = NSColor(Color(hex: hex))
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            color.setFill()
            NSBezierPath(ovalIn: inset).fill()
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let stroke = NSBezierPath(ovalIn: inset)
            stroke.lineWidth = 0.5
            stroke.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
#endif
