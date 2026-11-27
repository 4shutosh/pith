import AppKit
import CoreText
import SwiftUI

public enum ThemeMode: String, CaseIterable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public static func toggled(currentlyDark: Bool) -> ThemeMode {
        currentlyDark ? .light : .dark
    }

    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

public enum SurfaceStyle: String, CaseIterable, Codable, Identifiable {
    case warm
    case pure

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .warm: return "Warm"
        case .pure: return "True B&W"
        }
    }
}

public enum AccentPalette: String, CaseIterable, Codable, Identifiable {
    case amber
    case terracotta
    case sage
    case cobalt
    case plum
    case monochrome

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .amber: return "Amber"
        case .terracotta: return "Vermilion"
        case .sage: return "Jade"
        case .cobalt: return "Indigo"
        case .plum: return "Rose"
        case .monochrome: return "Mono"
        }
    }

    var darkAccentHex: UInt32 {
        switch self {
        case .amber: return 0xE0A463
        case .terracotta: return 0xF08A6C
        case .sage: return 0x68C7A1
        case .cobalt: return 0x94A8FA
        case .plum: return 0xEB94B4
        case .monochrome: return 0xF2EFE9
        }
    }

    var lightAccentHex: UInt32 {
        switch self {
        case .amber: return 0xA8641C
        case .terracotta: return 0xB83E21
        case .sage: return 0x1D7554
        case .cobalt: return 0x3D52C4
        case .plum: return 0xAD3964
        case .monochrome: return 0x111111
        }
    }

    var lightLinkHex: UInt32 {
        switch self {
        case .amber: return 0xA35F17
        case .terracotta: return 0xB0391D
        case .sage: return 0x196B4C
        case .cobalt: return 0x364AB8
        case .plum: return 0xA3335D
        case .monochrome: return 0x111111
        }
    }

    var lightSelectionHex: UInt32 {
        switch self {
        case .amber: return 0xD9964A
        case .terracotta: return 0xE6785A
        case .sage: return 0x4CAE8A
        case .cobalt: return 0x7388EC
        case .plum: return 0xD97296
        case .monochrome: return 0x111111
        }
    }

    var darkTagHex: UInt32 {
        switch self {
        case .amber, .terracotta, .cobalt, .plum: return 0x84B59F
        case .sage: return 0xD6B89A
        case .monochrome: return 0xB8B4AC
        }
    }

    var lightTagHex: UInt32 {
        switch self {
        case .amber, .terracotta, .cobalt, .plum: return 0x3C7A5E
        case .sage: return 0x8A5528
        case .monochrome: return 0x4A4844
        }
    }
}

public enum Theme {
    public static var currentAccent: AccentPalette = .amber
    public static var currentSurface: SurfaceStyle = .warm

    public static func swatchColor(for palette: AccentPalette) -> Color {
        accent(for: palette)
    }

    public static func accent(for palette: AccentPalette) -> Color {
        Color(nsColor: adaptive(dark: palette.darkAccentHex, light: palette.lightAccentHex))
    }

    public static func link(for palette: AccentPalette) -> Color {
        Color(nsColor: adaptive(dark: palette.darkAccentHex, light: palette.lightLinkHex))
    }
    public static let nsSidebar = surface(warmDark: 0x131210, warmLight: 0xF3F1EC, pureDark: 0x0A0A0A, pureLight: 0xF5F5F5)
    public static let nsCanvas = surface(warmDark: 0x181715, warmLight: 0xFBFAF7, pureDark: 0x000000, pureLight: 0xFFFFFF)
    public static let nsDivider = surface(warmDark: 0x252320, warmLight: 0xE7E3DB, pureDark: 0x1E1E1E, pureLight: 0xE5E5E5)
    public static let nsHover = surface(warmDark: 0x22201D, warmLight: 0xEFECE6, pureDark: 0x141414, pureLight: 0xF0F0F0)
    public static let nsSelected = surface(warmDark: 0x292622, warmLight: 0xE8E4DC, pureDark: 0x1D1D1D, pureLight: 0xE6E6E6)
    public static let nsElevated = surface(warmDark: 0x1F1D1A, warmLight: 0xFFFFFF, pureDark: 0x0F0F0F, pureLight: 0xFFFFFF)
    public static let nsElevatedBorder = surface(warmDark: 0x2E2B26, warmLight: 0xE0DCD3, pureDark: 0x262626, pureLight: 0xDCDCDC)
    public static let nsRowSelected = surface(warmDark: 0x292622, warmLight: 0xEFECE6, pureDark: 0x1A1A1A, pureLight: 0xEDEDED)
    public static let nsGuide = surface(warmDark: 0x292723, warmLight: 0xE6E2DA, pureDark: 0x222222, pureLight: 0xE5E5E5)
    public static let nsCodeBg = surface(warmDark: 0x23211D, warmLight: 0xF1EEE8, pureDark: 0x111111, pureLight: 0xF4F4F4)

    public static let nsTextStrong = adaptive(dark: 0xF2EFE9, light: 0x1B1916)
    public static let nsTextPrimary = adaptive(dark: 0xDDD9D0, light: 0x2A2723)
    public static let nsTextBody = adaptive(dark: 0xC7C2B8, light: 0x3B3731)
    public static let nsTextSecondary = adaptive(dark: 0x9A948A, light: 0x6A645B)
    public static let nsTextTertiary = adaptive(dark: 0x6F6A61, light: 0x8E887E)
    public static let nsBullet = adaptive(dark: 0x5A554E, light: 0xB3ADA3)

    public static let nsAccent = NSColor(name: nil) { appearance in
        let palette = Theme.currentAccent
        return NSColor(hex: ThemeMode.isDark(appearance) ? palette.darkAccentHex : palette.lightAccentHex)
    }
    public static let nsLink = NSColor(name: nil) { appearance in
        let palette = Theme.currentAccent
        return NSColor(hex: ThemeMode.isDark(appearance) ? palette.darkAccentHex : palette.lightLinkHex)
    }
    public static let nsTag = NSColor(name: nil) { appearance in
        let palette = Theme.currentAccent
        return NSColor(hex: ThemeMode.isDark(appearance) ? palette.darkTagHex : palette.lightTagHex)
    }
    public static let nsCodeText = adaptive(dark: 0xD6B89A, light: 0x8A5528)
    public static let nsDone = adaptive(dark: 0x73AD8F, light: 0x3D8562)
    public static let nsDanger = adaptive(dark: 0xD96B6B, light: 0xBF4540)

    public static let nsBracket = nsBullet
    public static let nsCaret = nsAccent
    public static let nsSelection = NSColor(name: nil) { appearance in
        let palette = Theme.currentAccent
        return NSColor(hex: ThemeMode.isDark(appearance) ? palette.darkAccentHex : palette.lightSelectionHex)
            .withAlphaComponent(0.24)
    }
    public static let nsShadow = adaptive(dark: 0x000000, light: 0x1B1916, alpha: 0.30)
    public static let nsClosedText = nsTextTertiary
    public static let nsClosedStrike = nsBullet

    public static var sidebar: Color { surfaceColor(warmDark: 0x131210, warmLight: 0xF3F1EC, pureDark: 0x0A0A0A, pureLight: 0xF5F5F5) }
    public static var canvas: Color { surfaceColor(warmDark: 0x181715, warmLight: 0xFBFAF7, pureDark: 0x000000, pureLight: 0xFFFFFF) }
    public static var divider: Color { surfaceColor(warmDark: 0x252320, warmLight: 0xE7E3DB, pureDark: 0x1E1E1E, pureLight: 0xE5E5E5) }
    public static var hover: Color { surfaceColor(warmDark: 0x22201D, warmLight: 0xEFECE6, pureDark: 0x141414, pureLight: 0xF0F0F0) }
    public static var selected: Color { surfaceColor(warmDark: 0x292622, warmLight: 0xE8E4DC, pureDark: 0x1D1D1D, pureLight: 0xE6E6E6) }
    public static var elevated: Color { surfaceColor(warmDark: 0x1F1D1A, warmLight: 0xFFFFFF, pureDark: 0x0F0F0F, pureLight: 0xFFFFFF) }
    public static var elevatedBorder: Color { surfaceColor(warmDark: 0x2E2B26, warmLight: 0xE0DCD3, pureDark: 0x262626, pureLight: 0xDCDCDC) }
    public static let shadow = Color(nsColor: nsShadow)
    public static var rowSelected: Color { surfaceColor(warmDark: 0x292622, warmLight: 0xEFECE6, pureDark: 0x1A1A1A, pureLight: 0xEDEDED) }
    public static var guide: Color { surfaceColor(warmDark: 0x292723, warmLight: 0xE6E2DA, pureDark: 0x222222, pureLight: 0xE5E5E5) }
    public static var codeBg: Color { surfaceColor(warmDark: 0x23211D, warmLight: 0xF1EEE8, pureDark: 0x111111, pureLight: 0xF4F4F4) }

    public static let textStrong = Color(nsColor: nsTextStrong)
    public static let textPrimary = Color(nsColor: nsTextPrimary)
    public static let textBody = Color(nsColor: nsTextBody)
    public static let textSecondary = Color(nsColor: nsTextSecondary)
    public static let textTertiary = Color(nsColor: nsTextTertiary)
    public static let bullet = Color(nsColor: nsBullet)

    public static var accent: Color { accent(for: currentAccent) }
    public static var link: Color { link(for: currentAccent) }
    public static var tag: Color {
        Color(nsColor: adaptive(dark: currentAccent.darkTagHex, light: currentAccent.lightTagHex))
    }
    public static let codeText = Color(nsColor: nsCodeText)
    public static var inProgress: Color { accent(for: currentAccent) }
    public static let done = Color(nsColor: nsDone)
    public static let danger = Color(nsColor: nsDanger)

    static func surface(warmDark: UInt32, warmLight: UInt32, pureDark: UInt32, pureLight: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = ThemeMode.isDark(appearance)
            let hex: UInt32 = switch (Theme.currentSurface, isDark) {
            case (.warm, true): warmDark
            case (.warm, false): warmLight
            case (.pure, true): pureDark
            case (.pure, false): pureLight
            }
            return NSColor(hex: hex)
        }
    }

    static func surfaceColor(warmDark: UInt32, warmLight: UInt32, pureDark: UInt32, pureLight: UInt32) -> Color {
        switch currentSurface {
        case .warm: return Color(nsColor: adaptive(dark: warmDark, light: warmLight))
        case .pure: return Color(nsColor: adaptive(dark: pureDark, light: pureLight))
        }
    }

    static func adaptive(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: ThemeMode.isDark(appearance) ? dark : light).withAlphaComponent(alpha)
        }
    }
}

public enum TypeScale {
    public static let pageTitle: CGFloat = 28
    public static let sectionTitle: CGFloat = 22
    public static let searchInput: CGFloat = 17
    public static let block: CGFloat = 15
    public static let listRow: CGFloat = 14
    public static let ui: CGFloat = 13
    public static let meta: CGFloat = 12
    public static let label: CGFloat = 11
    public static let code: CGFloat = 13.5

    public static let sans: Set<CGFloat> = [pageTitle, sectionTitle, searchInput, block, listRow, ui, meta, label]
    public static let mono: Set<CGFloat> = [code]
}

public enum Typography {
    public static let sansFamily = "Inter"
    public static let monoFamily = "JetBrains Mono"

    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(sansFamily, size: size).weight(weight)
    }

    public static func mono(_ size: CGFloat) -> Font {
        .custom(monoFamily, size: size)
    }

    public static func nsSans(_ size: CGFloat) -> NSFont {
        NSFontManager.shared.font(withFamily: sansFamily, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    @discardableResult
    public static func registerBundledFonts() -> [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var failed: [String] = []
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    failed.append(url.lastPathComponent)
                }
            }
        }
        return failed
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

public extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
