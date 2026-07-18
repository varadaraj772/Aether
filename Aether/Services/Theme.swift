import SwiftUI

struct ThemeColors {
    let backdrop: Color
    let text: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let success: Color
    let title: Color
    let snippet: Color

    static func palette(isDark: Bool) -> ThemeColors {
        if isDark {
            return ThemeColors(
                backdrop: Color(hex: 0x0B0B0D),
                text: Color(hex: 0xF2F2F7),
                textSecondary: Color(hex: 0xAEAEB2),
                textTertiary: Color(hex: 0x636366),
                accent: Color(hex: 0x0A84FF),
                success: Color(hex: 0x30D158),
                title: .white,
                snippet: Color(hex: 0xAEAEB2)
            )
        }

        return ThemeColors(
            backdrop: Color(hex: 0xECECF0),
            text: Color(hex: 0x1C1C1E),
            textSecondary: Color(hex: 0x636366),
            textTertiary: Color(hex: 0x8E8E93),
            accent: Color(hex: 0x0071E3),
            success: Color(hex: 0x248A3D),
            title: .black,
            snippet: Color(hex: 0x636366)
        )
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
