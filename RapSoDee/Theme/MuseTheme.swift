import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Muse theme — warm paper + leaf-green accents. Playful, cute, almost professional. Never flirtatious.
enum MuseTheme {
    static let leaf = Color(red: 0.122, green: 0.541, blue: 0.357) // #1F8A5B
    static let sage = Color(red: 0.910, green: 0.953, blue: 0.925) // #E8F3EC
    static let paper = Color(red: 0.969, green: 0.957, blue: 0.937) // #F7F4EF
    static let oatmeal = Color(red: 0.769, green: 0.722, blue: 0.647) // #C4B8A5
    static let ink = Color(red: 0.110, green: 0.169, blue: 0.141) // #1C2B24
    /// Loud but friendly — Approve / Calliope drafts mailbox
    static let approve = Color(red: 0.95, green: 0.55, blue: 0.12)
    static let approveSoft = Color(red: 0.98, green: 0.90, blue: 0.78)

    static let cornerLarge: CGFloat = 16
    static let cornerMed: CGFloat = 12

    static func accountTint(_ hex: String) -> Color {
        Color(hex: hex).opacity(0.14)
    }

    /// Soft pastel wash from a user-named flag color. Stronger than account tint so
    /// flag rows read clearly, but muted enough that list text stays readable in
    /// light and dark appearances.
    static func flagWash(_ hex: String, scheme: ColorScheme = .light) -> Color {
        let opacity = scheme == .dark ? 0.30 : 0.22
        return Color(hex: hex).opacity(opacity)
    }

    /// Stronger flag wash for the selected/highlighted row — clearer than soft wash
    /// so selection is obvious while still reading as that flag’s color.
    static func flagSelectionWash(_ hex: String, scheme: ColorScheme = .light) -> Color {
        let opacity = scheme == .dark ? 0.52 : 0.42
        return Color(hex: hex).opacity(opacity)
    }

    /// Neutral selection for unflagged rows — noticeable light grey on white/paper, never leaf-green.
    static func selectionGrey(scheme: ColorScheme = .light) -> Color {
        if scheme == .dark {
            return Color.white.opacity(0.18)
        }
        // Clear light-grey highlight so focused/selected rows read against white paper.
        return Color(red: 0.82, green: 0.81, blue: 0.79)
    }

    /// Even softer wash for reading-pane header chrome.
    static func flagHeaderWash(_ hex: String, scheme: ColorScheme = .light) -> Color {
        let opacity = scheme == .dark ? 0.22 : 0.14
        return Color(hex: hex).opacity(opacity)
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 31, 138, 91)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Convert to RRGGBB hex for persistence (ColorPicker ↔ stored string).
    /// Returns nil when the color cannot be represented in sRGB so callers can
    /// refuse to overwrite a stored hex (avoids wipe-on-rename ColorPicker churn).
    func toHexString() -> String {
        toHexStringOrNil() ?? "E07A3D"
    }

    func toHexStringOrNil() -> String? {
#if os(macOS)
        let ns = NSColor(self)
        // Prefer sRGB; fall back through device RGB before giving up.
        let rgb = ns.usingColorSpace(.sRGB)
            ?? ns.usingColorSpace(.deviceRGB)
            ?? ns.usingColorSpace(.genericRGB)
        guard let rgb else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
#else
        return nil
#endif
    }
}
