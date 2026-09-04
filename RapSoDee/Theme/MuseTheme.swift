import SwiftUI

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
}
