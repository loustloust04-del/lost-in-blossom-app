import Foundation
import SwiftUI
import UIKit

enum AppThemeMode: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return "自动跟着系统切换"
        case .light:
            return "始终使用浅色界面"
        case .dark:
            return "始终使用深色界面"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct ThemeColorValue: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    init(color: Color) {
        let native = UIColor(color)

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        native.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        self.init(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func withAlpha(_ alpha: Double) -> ThemeColorValue {
        ThemeColorValue(red: red, green: green, blue: blue, alpha: alpha)
    }

    func multipliedAlpha(_ multiplier: Double) -> ThemeColorValue {
        withAlpha(max(0, min(1, alpha * multiplier)))
    }

    func adjustedBrightness(_ brightness: Double, saturation: Double? = nil) -> ThemeColorValue {
        var hue: CGFloat = 0
        var currentSaturation: CGFloat = 0
        var currentBrightness: CGFloat = 0
        var alpha: CGFloat = 0

        let source = platformColor
        guard source.getHue(&hue, saturation: &currentSaturation, brightness: &currentBrightness, alpha: &alpha) else {
            return self
        }

        return Self.colorValue(
            from: Self.makePlatformColor(
                hue: hue,
                saturation: saturation.map { CGFloat($0) } ?? currentSaturation,
                brightness: CGFloat(brightness),
                alpha: alpha
            )
        )
    }

    private static func makePlatformColor(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat,
        alpha: CGFloat
    ) -> PlatformColor {
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha
        )
    }

    private static func colorValue(from color: PlatformColor) -> ThemeColorValue {
        let source = color

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        source.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ThemeColorValue(red: red, green: green, blue: blue, alpha: alpha)
    }

    typealias PlatformColor = UIColor
    var platformColor: UIColor {
        UIColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

struct ThemeTokenSet: Codable, Hashable {
    var mainBg: ThemeColorValue
    var sidebarBg: ThemeColorValue
    var userBubble: ThemeColorValue
    var assistantBubble: ThemeColorValue
    var accent: ThemeColorValue
    var textPrimary: ThemeColorValue
    var textSecondary: ThemeColorValue
    var textMuted: ThemeColorValue
    var favorite: ThemeColorValue
    var danger: ThemeColorValue
    var branchIndicator: ThemeColorValue

    static let palaceLightDefault = ThemeTokenSet(
        mainBg: ThemeColorValue(hex: 0xFFFBF6),
        sidebarBg: ThemeColorValue(hex: 0xF0EBE3),
        userBubble: ThemeColorValue(hex: 0xF8F4EF),
        assistantBubble: ThemeColorValue(hex: 0xF3F2EB),
        accent: ThemeColorValue(hex: 0xE7EEEC),
        textPrimary: ThemeColorValue(red: 0.24, green: 0.21, blue: 0.20),
        textSecondary: ThemeColorValue(red: 0.50, green: 0.47, blue: 0.44),
        textMuted: ThemeColorValue(red: 0.68, green: 0.65, blue: 0.62),
        favorite: ThemeColorValue(red: 0.94, green: 0.80, blue: 0.56),
        danger: ThemeColorValue(red: 0.88, green: 0.52, blue: 0.52),
        branchIndicator: ThemeColorValue(hex: 0x8EBD9F)
    )

    static let palaceDarkDefault = ThemeTokenSet(
        mainBg: ThemeColorValue(hex: 0x121311),
        sidebarBg: ThemeColorValue(hex: 0x171916),
        userBubble: ThemeColorValue(hex: 0x1C1F1B),
        assistantBubble: ThemeColorValue(hex: 0x20231F),
        accent: ThemeColorValue(hex: 0x27302D),
        textPrimary: ThemeColorValue(hex: 0xEEE7DF),
        textSecondary: ThemeColorValue(hex: 0xC8C0B6),
        textMuted: ThemeColorValue(hex: 0x948E86),
        favorite: ThemeColorValue(hex: 0xD6B06F),
        danger: ThemeColorValue(hex: 0xD77D7D),
        branchIndicator: ThemeColorValue(hex: 0x7FB993)
    )

    var previewColors: [Color] {
        [
            mainBg.color,
            sidebarBg.color,
            accent.color,
            branchIndicator.color
        ]
    }

    func tokens(for scheme: ColorScheme) -> ThemeTokenSet {
        self
    }

    func applyingPureBackground(for scheme: ColorScheme) -> ThemeTokenSet {
        var copy = self

        switch scheme {
        case .light:
            copy.mainBg = ThemeColorValue(hex: 0xFFFFFF)
            copy.sidebarBg = ThemeColorValue(hex: 0xF7F7F7)
            copy.userBubble = ThemeColorValue(hex: 0xF7F7F7)
            copy.assistantBubble = ThemeColorValue(hex: 0xF1F1F1)
        case .dark:
            copy.mainBg = ThemeColorValue(hex: 0x000000)
            copy.sidebarBg = ThemeColorValue(hex: 0x0B0B0B)
            copy.userBubble = ThemeColorValue(hex: 0x101010)
            copy.assistantBubble = ThemeColorValue(hex: 0x151515)
        @unknown default:
            break
        }

        return copy
    }

    func applyingBackgroundImageSurfaceStyle(for scheme: ColorScheme) -> ThemeTokenSet {
        var copy = self

        switch scheme {
        case .light:
            copy.userBubble = copy.userBubble.multipliedAlpha(0.90)
            copy.assistantBubble = copy.assistantBubble.multipliedAlpha(0.90)
            copy.accent = copy.accent.multipliedAlpha(0.76)
        case .dark:
            copy.userBubble = copy.userBubble.multipliedAlpha(0.84)
            copy.assistantBubble = copy.assistantBubble.multipliedAlpha(0.84)
            copy.accent = copy.accent.multipliedAlpha(0.72)
        @unknown default:
            break
        }

        return copy
    }

    func generatingDarkDraftFromLight() -> ThemeTokenSet {
        ThemeTokenSet(
            mainBg: mainBg.adjustedBrightness(0.09, saturation: 0.12),
            sidebarBg: sidebarBg.adjustedBrightness(0.12, saturation: 0.12),
            userBubble: userBubble.adjustedBrightness(0.15, saturation: 0.10),
            assistantBubble: assistantBubble.adjustedBrightness(0.18, saturation: 0.12),
            accent: accent.adjustedBrightness(0.24, saturation: 0.20),
            textPrimary: textPrimary.adjustedBrightness(0.92, saturation: 0.10),
            textSecondary: textSecondary.adjustedBrightness(0.72, saturation: 0.12),
            textMuted: textMuted.adjustedBrightness(0.55, saturation: 0.10),
            favorite: favorite.adjustedBrightness(0.78),
            danger: danger.adjustedBrightness(0.80),
            branchIndicator: branchIndicator.adjustedBrightness(0.70)
        )
    }
}

struct ThemeBackgroundStyle: Codable, Hashable {
    static let opacityRange: ClosedRange<Double> = 0.08...0.92
    static let horizontalOffsetRange: ClosedRange<Double> = -240...240
    static let verticalOffsetRange: ClosedRange<Double> = -320...320

    var opacity: Double?
    var offsetX: Double?
    var offsetY: Double?

    init(
        opacity: Double? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) {
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    func resolvedOpacity(for scheme: ColorScheme) -> Double {
        let fallback = scheme == .dark ? 0.52 : 0.36
        return Self.clamp(
            opacity ?? fallback,
            to: Self.opacityRange
        )
    }

    var resolvedOffsetX: CGFloat {
        CGFloat(Self.clamp(offsetX ?? 0, to: Self.horizontalOffsetRange))
    }

    var resolvedOffsetY: CGFloat {
        CGFloat(Self.clamp(offsetY ?? 0, to: Self.verticalOffsetRange))
    }

    var normalized: ThemeBackgroundStyle {
        ThemeBackgroundStyle(
            opacity: opacity.map { Self.clamp($0, to: Self.opacityRange) },
            offsetX: offsetX.map { Self.clamp($0, to: Self.horizontalOffsetRange) },
            offsetY: offsetY.map { Self.clamp($0, to: Self.verticalOffsetRange) }
        )
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct AppThemeDefinition: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var light: ThemeTokenSet
    var dark: ThemeTokenSet
    var backgroundImageFileName: String?
    var backgroundStyle: ThemeBackgroundStyle?

    func tokens(for scheme: ColorScheme) -> ThemeTokenSet {
        scheme == .dark ? dark : light
    }

    var isCustomDraft: Bool {
        id == Self.customTheme.id
    }

    var isEditable: Bool {
        !isBuiltIn
    }

    var isDeletable: Bool {
        !isBuiltIn && !isCustomDraft
    }

    var hasBackgroundImage: Bool {
        backgroundImageFileName != nil
    }

    var resolvedBackgroundStyle: ThemeBackgroundStyle {
        (backgroundStyle ?? ThemeBackgroundStyle()).normalized
    }

    static let defaultTheme = AppThemeDefinition(
        id: "default",
        name: "宫殿默认",
        isBuiltIn: true,
        light: .palaceLightDefault,
        dark: .palaceDarkDefault,
        backgroundImageFileName: nil,
        backgroundStyle: nil
    )

    static let customTheme = AppThemeDefinition(
        id: "custom",
        name: "自定义主题",
        isBuiltIn: false,
        light: .palaceLightDefault,
        dark: .palaceDarkDefault,
        backgroundImageFileName: nil,
        backgroundStyle: nil
    )

    static let seedThemes: [AppThemeDefinition] = [
        .defaultTheme,
        .customTheme
    ]

    var previewColors: [Color] {
        light.previewColors
    }
}
