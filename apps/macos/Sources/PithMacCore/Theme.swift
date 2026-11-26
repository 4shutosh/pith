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

public enum Theme {
    public static let nsSidebar = adaptive(dark: 0x131210, light: 0xF3F1EC)
    public static let nsCanvas = adaptive(dark: 0x181715, light: 0xFBFAF7)
    public static let nsDivider = adaptive(dark: 0x252320, light: 0xE7E3DB)
    public static let nsHover = adaptive(dark: 0x22201D, light: 0xEFECE6)
    public static let nsSelected = adaptive(dark: 0x292622, light: 0xE8E4DC)
    public static let nsElevated = adaptive(dark: 0x1F1D1A, light: 0xFFFFFF)
    public static let nsElevatedBorder = adaptive(dark: 0x2E2B26, light: 0xE0DCD3)
    public static let nsRowSelected = adaptive(dark: 0x292622, light: 0xEFECE6)
    public static let nsGuide = adaptive(dark: 0x292723, light: 0xE6E2DA)
    public static let nsCodeBg = adaptive(dark: 0x23211D, light: 0xF1EEE8)

    public static let nsTextStrong = adaptive(dark: 0xF2EFE9, light: 0x1B1916)
    public static let nsTextPrimary = adaptive(dark: 0xDDD9D0, light: 0x2A2723)
    public static let nsTextBody = adaptive(dark: 0xC7C2B8, light: 0x3B3731)
    public static let nsTextSecondary = adaptive(dark: 0x9A948A, light: 0x6A645B)
    public static let nsTextTertiary = adaptive(dark: 0x6F6A61, light: 0x8E887E)
    public static let nsBullet = adaptive(dark: 0x5A554E, light: 0xB3ADA3)

    public static let nsAccent = adaptive(dark: 0xE0A463, light: 0xA8641C)
    public static let nsLink = adaptive(dark: 0xE0A463, light: 0xA35F17)
    public static let nsTag = adaptive(dark: 0x84B59F, light: 0x3C7A5E)
    public static let nsCodeText = adaptive(dark: 0xD6B89A, light: 0x8A5528)
    public static let nsDone = adaptive(dark: 0x73AD8F, light: 0x3D8562)
    public static let nsDanger = adaptive(dark: 0xD96B6B, light: 0xBF4540)

    public static let nsBracket = nsBullet
    public static let nsCaret = nsAccent
    public static let nsSelection = adaptive(dark: 0xE0A463, light: 0xD9964A, alpha: 0.24)
    public static let nsClosedText = nsTextTertiary
    public static let nsClosedStrike = nsBullet

    public static let sidebar = Color(nsColor: nsSidebar)
    public static let canvas = Color(nsColor: nsCanvas)
    public static let divider = Color(nsColor: nsDivider)
    public static let hover = Color(nsColor: nsHover)
    public static let selected = Color(nsColor: nsSelected)
    public static let elevated = Color(nsColor: nsElevated)
    public static let elevatedBorder = Color(nsColor: nsElevatedBorder)
    public static let rowSelected = Color(nsColor: nsRowSelected)
    public static let guide = Color(nsColor: nsGuide)
    public static let codeBg = Color(nsColor: nsCodeBg)

    public static let textStrong = Color(nsColor: nsTextStrong)
    public static let textPrimary = Color(nsColor: nsTextPrimary)
    public static let textBody = Color(nsColor: nsTextBody)
    public static let textSecondary = Color(nsColor: nsTextSecondary)
    public static let textTertiary = Color(nsColor: nsTextTertiary)
    public static let bullet = Color(nsColor: nsBullet)

    public static let accent = Color(nsColor: nsAccent)
    public static let link = Color(nsColor: nsLink)
    public static let tag = Color(nsColor: nsTag)
    public static let codeText = Color(nsColor: nsCodeText)
    public static let inProgress = Color(nsColor: nsAccent)
    public static let done = Color(nsColor: nsDone)
    public static let danger = Color(nsColor: nsDanger)

    static func adaptive(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: ThemeMode.isDark(appearance) ? dark : light).withAlphaComponent(alpha)
        }
    }
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
