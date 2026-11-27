import Foundation

public enum JournalDateFormat: String, CaseIterable, Codable, Identifiable {
    case iso
    case medium
    case weekday
    case dayFirst

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iso: return "ISO"
        case .medium: return "Short"
        case .weekday: return "Full"
        case .dayFirst: return "Day first"
        }
    }

    public func format(_ isoDate: String) -> String {
        guard self != .iso else { return isoDate }
        guard let date = Self.parseISO(isoDate) else { return isoDate }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        switch self {
        case .iso: return isoDate
        case .medium: formatter.dateFormat = "MMM d, yyyy"
        case .weekday: formatter.dateFormat = "EEE, MMM d, yyyy"
        case .dayFirst: formatter.dateFormat = "d MMM yyyy"
        }
        return formatter.string(from: date)
    }

    private static func parseISO(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @Published public var accent: AccentPalette {
        didSet {
            Theme.currentAccent = accent
            defaults.set(accent.rawValue, forKey: accentKey)
        }
    }

    @Published public var surface: SurfaceStyle {
        didSet {
            Theme.currentSurface = surface
            defaults.set(surface.rawValue, forKey: surfaceKey)
        }
    }

    @Published public var dateFormat: JournalDateFormat {
        didSet {
            defaults.set(dateFormat.rawValue, forKey: dateFormatKey)
        }
    }

    @Published public var showLinkBrackets: Bool {
        didSet {
            defaults.set(showLinkBrackets, forKey: linkBracketsKey)
        }
    }

    private let defaults: UserDefaults
    private let accentKey = "pith.accent"
    private let surfaceKey = "pith.surface"
    private let dateFormatKey = "pith.dateFormat"
    private let linkBracketsKey = "pith.showLinkBrackets"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedAccent = defaults.string(forKey: accentKey).flatMap(AccentPalette.init(rawValue:)) ?? .amber
        let storedSurface = defaults.string(forKey: surfaceKey).flatMap(SurfaceStyle.init(rawValue:)) ?? .warm
        let storedDate = defaults.string(forKey: dateFormatKey).flatMap(JournalDateFormat.init(rawValue:)) ?? .iso
        let storedBrackets = defaults.object(forKey: linkBracketsKey) as? Bool ?? true
        self.accent = storedAccent
        self.surface = storedSurface
        self.dateFormat = storedDate
        self.showLinkBrackets = storedBrackets
        Theme.currentAccent = storedAccent
        Theme.currentSurface = storedSurface
    }

    public func formatJournalTitle(_ raw: String) -> String {
        dateFormat.format(raw)
    }

    public func resetToDefaults() {
        accent = .amber
        surface = .warm
        dateFormat = .iso
        showLinkBrackets = true
    }
}
