import SwiftUI
import UIKit

enum Theme {
    private static var currentTokens: ThemeTokenSet {
        ThemeManager.shared.currentTokenSet
    }

    static var mainBg: Color { currentTokens.mainBg.color }
    static var sidebarBg: Color { currentTokens.sidebarBg.color }
    static var userBubble: Color { currentTokens.userBubble.color }
    static var assistantBubble: Color { currentTokens.assistantBubble.color }
    static var accent: Color { currentTokens.accent.color }
    static var textPrimary: Color { currentTokens.textPrimary.color }
    static var textSecondary: Color { currentTokens.textSecondary.color }
    static var textMuted: Color { currentTokens.textMuted.color }
    static var favorite: Color { currentTokens.favorite.color }
    static var danger: Color { currentTokens.danger.color }
    static var branchIndicator: Color { currentTokens.branchIndicator.color }
    static var activeScheme: ColorScheme { ThemeManager.shared.activeScheme }

    static var platformMainBackgroundColor: UIColor { currentTokens.mainBg.platformColor }

    static let bubbleCornerRadius: CGFloat = 16
    static let bubblePadding: CGFloat = 14
    static let bubbleSpacing: CGFloat = 6
    static let bubbleMaxWidthRatio: CGFloat = 0.75
    static let cardShadow = Color.black.opacity(0.04)
    static let cardShadowRadius: CGFloat = 3

    enum SettingsFont {
        static let sectionHeader: CGFloat = 16
        static let label: CGFloat = 15
        static let body: CGFloat = 14
        static let secondary: CGFloat = 13
        static let caption: CGFloat = 11
        static let badge: CGFloat = 11
        static let mono: CGFloat = 13
    }

    // 全局别名，方便非设置页使用
    typealias F = SettingsFont

    static let optionRowVerticalPadding: CGFloat = 12
    static let optionRowSpacing: CGFloat = 2

    static var cream: Color { mainBg }
    static var paleBlue: Color { accent }
    static var softBlue: Color { branchIndicator }
    static var userCard: Color { userBubble }
    static var assistantCard: Color { assistantBubble }
    static let cardCornerRadius = bubbleCornerRadius
    static let cardPadding = bubblePadding
    static let cardSpacing = bubbleSpacing
}

// MARK: - Hex Color Extension
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// Init from a hex string like "6B7CB3" or "#6B7CB3"
    init(hexString: String) {
        let stripped = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt(stripped, radix: 16) ?? 0x6B7CB3
        self.init(hex: value)
    }

    /// 输出 "#RRGGBB" 字符串（WebView 主题变量用）。
    func toHex() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
