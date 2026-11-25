import AppKit
import CoreText
import SwiftUI

public enum Theme {
    public static let window = Color(hex: 0x0B0B0C)
    public static let panel = Color(hex: 0x121214)
    public static let panelBorder = Color(hex: 0x1F1F22)
    public static let divider = Color(hex: 0x1C1C1F)
    public static let selected = Color(hex: 0x1C1C1F)
    public static let hover = Color(hex: 0x161618)
    public static let elevated = Color(hex: 0x161618)
    public static let elevatedBorder = Color(hex: 0x2A2A2E)
    public static let rowSelected = Color(hex: 0x222226)
    public static let editingFill = Color(hex: 0x18181B)
    public static let editingBorder = Color(hex: 0x26262A)
    public static let guide = Color(hex: 0x232326)
    public static let textStrong = Color(hex: 0xF4F4F6)
    public static let textPrimary = Color(hex: 0xE8E8EA)
    public static let textBody = Color(hex: 0xD4D5D9)
    public static let textSecondary = Color(hex: 0x9A9CA3)
    public static let textTertiary = Color(hex: 0x7A7C83)
    public static let bullet = Color(hex: 0x6C6E75)
    public static let accent = Color(hex: 0x5E6AD2)
    public static let link = Color(hex: 0x9AA2F5)
    public static let inProgress = Color(hex: 0xE2B340)
    public static let healthy = Color(hex: 0x4CB782)
    public static let danger = Color(hex: 0xEB5757)

    public static let nsTextStrong = NSColor(hex: 0xF4F4F6)
    public static let nsLink = NSColor(hex: 0x9AA2F5)
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
