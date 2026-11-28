import CoreGraphics
import Foundation
import PithCore

private let gregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

public struct JournalDay: Hashable, Comparable, Identifiable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    fileprivate init(date: Date) {
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    public var id: String { iso }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var calendarMonth: JournalMonth {
        JournalMonth(year: year, month: month)
    }

    public var weekdayName: String {
        gregorian.weekdaySymbols[gregorian.component(.weekday, from: date) - 1]
    }

    public var weekdayFromMonday: Int {
        let sundayFirst = gregorian.component(.weekday, from: date)
        return (sundayFirst + 5) % 7
    }

    public func adding(days: Int) -> JournalDay {
        JournalDay(date: gregorian.date(byAdding: .day, value: days, to: date) ?? date)
    }

    public func adding(months: Int) -> JournalDay {
        JournalDay(date: gregorian.date(byAdding: .month, value: months, to: date) ?? date)
    }

    public func days(since other: JournalDay) -> Int {
        gregorian.dateComponents([.day], from: other.date, to: date).day ?? 0
    }

    public static func < (lhs: JournalDay, rhs: JournalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private var date: Date {
        gregorian.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }
}

public struct JournalMonth: Hashable, Comparable, Identifiable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        let index = year * 12 + month - 1
        self.year = index >= 0 ? index / 12 : (index - 11) / 12
        self.month = index - self.year * 12 + 1
    }

    public var id: String {
        String(format: "%04d-%02d", year, month)
    }

    public var title: String {
        "\(gregorian.standaloneMonthSymbols[month - 1]) \(year)"
    }

    public var first: JournalDay {
        JournalDay(date: gregorian.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date(timeIntervalSince1970: 0))
    }

    public var days: [JournalDay] {
        let count = first.adding(months: 1).days(since: first)
        return (0..<count).map { first.adding(days: $0) }
    }

    public var leadingBlanks: Int {
        first.weekdayFromMonday
    }

    public var weeks: [[JournalDay?]] {
        let cells: [JournalDay?] = Array(repeating: nil, count: leadingBlanks) + days.map { $0 }
        let padded = cells + Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<$0 + 7]) }
    }

    public func adding(months: Int) -> JournalMonth {
        JournalMonth(year: year, month: month + months)
    }

    public static func < (lhs: JournalMonth, rhs: JournalMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public static let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"]
}

public enum JournalInk: Int, Comparable, CaseIterable {
    case none
    case light
    case medium
    case strong
    case full

    public init(blockCount: UInt32) {
        switch blockCount {
        case 0: self = .none
        case 1...2: self = .light
        case 3...6: self = .medium
        case 7...15: self = .strong
        default: self = .full
        }
    }

    public static func < (lhs: JournalInk, rhs: JournalInk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct JournalStats: Equatable {
    public let writtenDays: Int
    public let since: JournalDay?
    public let currentStreak: Int
    public let longestStreak: Int

    public init(writtenDays: Int, since: JournalDay?, currentStreak: Int, longestStreak: Int) {
        self.writtenDays = writtenDays
        self.since = since
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
    }
}

public struct JournalHistory: Equatable {
    public let days: [JournalDay: FfiJournalDay]
    public let earliest: JournalDay?

    public static let empty = JournalHistory([])

    public init(_ activity: [FfiJournalDay]) {
        var days: [JournalDay: FfiJournalDay] = [:]
        for entry in activity {
            if let day = JournalDay(iso: entry.date) {
                days[day] = entry
            }
        }
        self.days = days
        earliest = days.keys.min()
    }

    public func ink(_ day: JournalDay) -> JournalInk {
        JournalInk(blockCount: days[day]?.blockCount ?? 0)
    }

    public func entry(_ day: JournalDay) -> FfiJournalDay? {
        days[day]
    }

    public func writtenCount(in month: JournalMonth) -> Int {
        days.keys.reduce(0) { $0 + ($1.calendarMonth == month ? 1 : 0) }
    }

    public func months(today: JournalDay, selected: JournalDay) -> [JournalMonth] {
        let newest = max(today.calendarMonth, selected.calendarMonth)
        let oldest = [earliest?.calendarMonth, today.calendarMonth, selected.calendarMonth].compactMap { $0 }.min() ?? newest
        var out: [JournalMonth] = []
        var month = newest
        while month >= oldest {
            out.append(month)
            month = month.adding(months: -1)
        }
        return out
    }

    public func writtenDay(before day: JournalDay) -> JournalDay? {
        days.keys.filter { $0 < day }.max()
    }

    public func writtenDay(after day: JournalDay) -> JournalDay? {
        days.keys.filter { $0 > day }.min()
    }

    public func stats(today: JournalDay) -> JournalStats {
        let sorted = days.keys.sorted()
        var longest = 0
        var run = 0
        var previous: JournalDay?
        for day in sorted {
            run = previous.map { day.days(since: $0) == 1 } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        var current = 0
        var cursor = days[today] == nil ? today.adding(days: -1) : today
        while days[cursor] != nil {
            current += 1
            cursor = cursor.adding(days: -1)
        }
        return JournalStats(writtenDays: days.count, since: earliest, currentStreak: current, longestStreak: longest)
    }
}

public enum JournalCalendarKeyAction: Equatable {
    case moved
    case open(JournalDay)
}

public struct JournalCalendarState: Equatable {
    public var selected: JournalDay

    public init(selected: JournalDay) {
        self.selected = selected
    }

    public mutating func handleKey(_ stroke: KeyStroke, today: JournalDay, history: JournalHistory) -> JournalCalendarKeyAction? {
        switch (stroke.key, stroke.modifiers) {
        case (.left, []): selected = selected.adding(days: -1)
        case (.right, []): selected = selected.adding(days: 1)
        case (.up, []): selected = selected.adding(days: -7)
        case (.down, []): selected = selected.adding(days: 7)
        case (.pageUp, []): selected = selected.adding(months: -1)
        case (.pageDown, []): selected = selected.adding(months: 1)
        case (.left, .option):
            guard let day = history.writtenDay(before: selected) else { return .moved }
            selected = day
        case (.right, .option):
            guard let day = history.writtenDay(after: selected) else { return .moved }
            selected = day
        case (.character("t"), []): selected = today
        case (.returnKey, []): return .open(selected)
        default: return nil
        }
        return .moved
    }
}

public enum JournalRelative {
    public static func label(_ day: JournalDay, today: JournalDay) -> String {
        switch today.days(since: day) {
        case 0: return "Today"
        case 1: return "Yesterday"
        case -1: return "Tomorrow"
        case let past where past > 1: return "\(past) days ago"
        case let future: return "In \(-future) days"
        }
    }
}

public struct JournalCalendarLayout: Equatable {
    public static let sideCell: CGFloat = 34
    public static let maximumCell: CGFloat = 48
    public static let gap: CGFloat = 4
    public static let previewMinimumWidth: CGFloat = 300
    public static let paneGap: CGFloat = 32

    public let showsSidePreview: Bool
    public let cell: CGFloat

    public init(width: CGFloat) {
        let sideGrid = Self.sideCell * 7 + Self.gap * 6
        showsSidePreview = width >= sideGrid + Self.paneGap + Self.previewMinimumWidth
        cell = showsSidePreview ? Self.sideCell : max(0, min(Self.maximumCell, ((width - Self.gap * 6) / 7).rounded(.down)))
    }

    public var gridWidth: CGFloat {
        cell * 7 + Self.gap * 6
    }
}
