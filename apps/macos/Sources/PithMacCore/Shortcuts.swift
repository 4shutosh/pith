import AppKit
import Foundation
import SwiftUI

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)

    public init(nsFlags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        if nsFlags.contains(.command) { result.insert(.command) }
        if nsFlags.contains(.shift) { result.insert(.shift) }
        if nsFlags.contains(.option) { result.insert(.option) }
        if nsFlags.contains(.control) { result.insert(.control) }
        self = result
    }

    public var nsFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    public var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    public var symbols: [String] {
        var out: [String] = []
        if contains(.control) { out.append("⌃") }
        if contains(.option) { out.append("⌥") }
        if contains(.shift) { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        return out
    }
}

public enum ShortcutKey: Codable, Hashable, Equatable {
    case character(String)
    case returnKey
    case escape
    case up
    case down
    case left
    case right
    case tab
    case backspace
    case forwardDelete

    public init?(key: Key) {
        switch key {
        case .returnKey: self = .returnKey
        case .escape: self = .escape
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .tab: self = .tab
        case .backspace: self = .backspace
        case .forwardDelete: self = .forwardDelete
        case let .character(ch):
            guard let scalar = ch.lowercased().first else { return nil }
            self = .character(String(scalar))
        case .other:
            return nil
        }
    }

    public var key: Key {
        switch self {
        case let .character(ch): return .character(ch)
        case .returnKey: return .returnKey
        case .escape: return .escape
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .tab: return .tab
        case .backspace: return .backspace
        case .forwardDelete: return .forwardDelete
        }
    }

    public var displaySymbol: String {
        switch self {
        case let .character(ch):
            if ch == " " { return "Space" }
            return ch.uppercased()
        case .returnKey: return "↵"
        case .escape: return "esc"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .tab: return "⇥"
        case .backspace: return "⌫"
        case .forwardDelete: return "⌦"
        }
    }

    public var keyEquivalent: KeyEquivalent? {
        switch self {
        case let .character(ch):
            guard let first = ch.first else { return nil }
            return KeyEquivalent(first)
        case .returnKey: return .return
        case .escape: return .escape
        case .up: return .upArrow
        case .down: return .downArrow
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .tab: return .tab
        case .backspace: return .delete
        case .forwardDelete: return .deleteForward
        }
    }
}

public struct KeyCombo: Codable, Hashable, Equatable {
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers

    public init(_ key: ShortcutKey, _ modifiers: ShortcutModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init?(stroke: KeyStroke) {
        guard let shortcutKey = ShortcutKey(key: stroke.key) else { return nil }
        let mods = ShortcutModifiers(nsFlags: stroke.modifiers)
        if case .character = shortcutKey, mods.isEmpty {
            return nil
        }
        self.key = shortcutKey
        self.modifiers = mods
    }

    public var keycaps: [String] {
        modifiers.symbols + [key.displaySymbol]
    }

    public var displayString: String {
        keycaps.joined()
    }

    public var swiftUIShortcut: KeyboardShortcut? {
        guard let equiv = key.keyEquivalent else { return nil }
        return KeyboardShortcut(equiv, modifiers: modifiers.eventModifiers)
    }

    public func matches(_ stroke: KeyStroke) -> Bool {
        stroke.key == key.key && ShortcutModifiers(nsFlags: stroke.modifiers) == modifiers
    }
}

public enum ShortcutScope: String, Codable, Equatable {
    case global
    case editor
    case selection

    public func overlaps(with other: ShortcutScope) -> Bool {
        self == .global || other == .global || self == other
    }
}

public enum ShortcutCategory: String, CaseIterable, Identifiable {
    case navigation
    case page
    case editing
    case selection
    case window

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .navigation: return "Navigation"
        case .page: return "Page & Outliner"
        case .editing: return "Editing & Formatting"
        case .selection: return "Block Selection"
        case .window: return "Window"
        }
    }
}

public enum AppAction: String, CaseIterable, Codable, Identifiable {
    case openPalette
    case goToToday
    case openJournals
    case openAllPages
    case searchShortcuts
    case openShortcuts
    case goBack
    case goForward
    case previousDay
    case nextDay

    case newPage
    case focusEditor
    case findInPage
    case expandAll
    case collapseAll
    case toggleFavorite
    case renamePage
    case deletePage

    case cycleTask
    case bold
    case italic
    case strikethrough
    case highlight
    case moveBlockUp
    case moveBlockDown
    case toggleBlockCollapse
    case copyBlockMarkdown

    case moveSelectionUp
    case moveSelectionDown
    case cycleSelectedTasks
    case selectAllBlocks

    case toggleSidebar
    case toggleTheme
    case openSettings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openPalette: return "Command Palette & Search"
        case .goToToday: return "Go to Today and Write"
        case .newPage: return "New Page"
        case .focusEditor: return "Focus Editor"
        case .openJournals: return "Go to Journals"
        case .openAllPages: return "Go to All Pages"
        case .searchShortcuts: return "Search Keyboard Shortcuts"
        case .openShortcuts: return "Keyboard Shortcuts Settings"
        case .goBack: return "Navigate Back"
        case .goForward: return "Navigate Forward"
        case .previousDay: return "Previous Journal Day"
        case .nextDay: return "Next Journal Day"
        case .findInPage: return "Find in Page"
        case .expandAll: return "Expand All Blocks"
        case .collapseAll: return "Collapse All Blocks"
        case .toggleFavorite: return "Toggle Favorite"
        case .renamePage: return "Rename Page"
        case .deletePage: return "Delete Page…"
        case .cycleTask: return "Cycle Task Status"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .highlight: return "Highlight"
        case .moveBlockUp: return "Move Block Up"
        case .moveBlockDown: return "Move Block Down"
        case .toggleBlockCollapse: return "Collapse / Expand Block"
        case .copyBlockMarkdown: return "Copy Block as Markdown"
        case .moveSelectionUp: return "Move Selected Blocks Up"
        case .moveSelectionDown: return "Move Selected Blocks Down"
        case .cycleSelectedTasks: return "Cycle Selected Tasks"
        case .selectAllBlocks: return "Select All Blocks"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleTheme: return "Toggle Light / Dark"
        case .openSettings: return "Settings"
        }
    }

    public var keywords: String {
        switch self {
        case .openPalette: return "search command palette quick switcher"
        case .goToToday: return "today journal daily write now"
        case .newPage: return "create add untitled blank note"
        case .focusEditor: return "write type edit cursor start typing"
        case .openJournals: return "today daily notes"
        case .openAllPages: return "directory list index"
        case .searchShortcuts: return "keys keybindings hotkeys shortcut lookup cheat sheet"
        case .openShortcuts: return "keys keybindings hotkeys customize settings preferences"
        case .goBack: return "back history previous"
        case .goForward: return "forward history next"
        case .previousDay: return "yesterday journal"
        case .nextDay: return "tomorrow journal"
        case .findInPage: return "search filter text highlight"
        case .expandAll: return "unfold open tree"
        case .collapseAll: return "fold close tree"
        case .toggleFavorite: return "star pin bookmark"
        case .renamePage: return "title edit"
        case .deletePage: return "remove trash"
        case .cycleTask: return "todo doing done"
        case .bold: return "strong format"
        case .italic: return "emphasis format"
        case .strikethrough: return "strike format"
        case .highlight: return "mark format"
        case .moveBlockUp: return "reorder swap"
        case .moveBlockDown: return "reorder swap"
        case .toggleBlockCollapse: return "fold unfold children"
        case .copyBlockMarkdown: return "export clipboard"
        case .moveSelectionUp: return "bulk reorder"
        case .moveSelectionDown: return "bulk reorder"
        case .cycleSelectedTasks: return "bulk todo done"
        case .selectAllBlocks: return "bulk highlight"
        case .toggleSidebar: return "sidebar drawer panel hide show"
        case .toggleTheme: return "theme appearance dark light"
        case .openSettings: return "settings preferences theme accent color date format"
        }
    }

    public var category: ShortcutCategory {
        switch self {
        case .openPalette, .goToToday, .openJournals, .openAllPages, .searchShortcuts, .openShortcuts,
             .goBack, .goForward, .previousDay, .nextDay:
            return .navigation
        case .newPage, .focusEditor, .findInPage, .expandAll, .collapseAll, .toggleFavorite, .renamePage, .deletePage:
            return .page
        case .cycleTask, .bold, .italic, .strikethrough, .highlight,
             .moveBlockUp, .moveBlockDown, .toggleBlockCollapse, .copyBlockMarkdown:
            return .editing
        case .moveSelectionUp, .moveSelectionDown, .cycleSelectedTasks, .selectAllBlocks:
            return .selection
        case .toggleSidebar, .toggleTheme, .openSettings:
            return .window
        }
    }

    public var scope: ShortcutScope {
        switch category {
        case .navigation, .page, .window: return .global
        case .editing: return .editor
        case .selection: return .selection
        }
    }

    public var inPalette: Bool {
        scope == .global && self != .openPalette
    }

    public var defaultCombo: KeyCombo? {
        switch self {
        case .openPalette: return KeyCombo(.character("k"), [.command])
        case .goToToday: return KeyCombo(.character("t"), [.command])
        case .newPage: return KeyCombo(.character("n"), [.command])
        case .focusEditor: return KeyCombo(.character("e"), [.command])
        case .openJournals: return KeyCombo(.character("j"), [.command])
        case .openAllPages: return KeyCombo(.character("p"), [.command, .shift])
        case .searchShortcuts: return KeyCombo(.character("/"), [.command])
        case .openShortcuts: return KeyCombo(.character("/"), [.command, .option])
        case .goBack: return KeyCombo(.character("["), [.command])
        case .goForward: return KeyCombo(.character("]"), [.command])
        case .previousDay: return KeyCombo(.character("["), [.command, .option])
        case .nextDay: return KeyCombo(.character("]"), [.command, .option])
        case .findInPage: return KeyCombo(.character("f"), [.command])
        case .expandAll: return KeyCombo(.character("."), [.command, .option])
        case .collapseAll: return KeyCombo(.character("."), [.command, .shift])
        case .toggleFavorite: return KeyCombo(.character("d"), [.command])
        case .renamePage: return KeyCombo(.character("r"), [.command, .shift])
        case .deletePage: return nil
        case .cycleTask: return KeyCombo(.returnKey, [.command])
        case .bold: return KeyCombo(.character("b"), [.command])
        case .italic: return KeyCombo(.character("i"), [.command])
        case .strikethrough: return KeyCombo(.character("x"), [.command, .shift])
        case .highlight: return KeyCombo(.character("h"), [.command, .shift])
        case .moveBlockUp: return KeyCombo(.up, [.option])
        case .moveBlockDown: return KeyCombo(.down, [.option])
        case .toggleBlockCollapse: return KeyCombo(.character("."), [.command])
        case .copyBlockMarkdown: return KeyCombo(.character("c"), [.command, .shift])
        case .moveSelectionUp: return KeyCombo(.up, [.option])
        case .moveSelectionDown: return KeyCombo(.down, [.option])
        case .cycleSelectedTasks: return KeyCombo(.returnKey, [.command])
        case .selectAllBlocks: return KeyCombo(.character("a"), [.command])
        case .toggleSidebar: return KeyCombo(.character("\\"), [.command])
        case .toggleTheme: return KeyCombo(.character("l"), [.command, .shift])
        case .openSettings: return KeyCombo(.character(","), [.command])
        }
    }
}

public enum BindingProblem: Equatable {
    case needsModifier
    case reservedBySystem(String)
}

public extension KeyCombo {
    static let systemReserved: [KeyCombo: String] = [
        KeyCombo(.character("c"), [.command]): "Copy",
        KeyCombo(.character("v"), [.command]): "Paste",
        KeyCombo(.character("x"), [.command]): "Cut",
        KeyCombo(.character("z"), [.command]): "Undo",
        KeyCombo(.character("z"), [.command, .shift]): "Redo",
        KeyCombo(.character("a"), [.command]): "Select All",
        KeyCombo(.character("q"), [.command]): "Quit",
        KeyCombo(.character("w"), [.command]): "Close Window",
        KeyCombo(.character("h"), [.command]): "Hide",
        KeyCombo(.character("m"), [.command]): "Minimize",
        KeyCombo(.character(","), [.command]): "Settings",
    ]

    var hasCommandLikeModifier: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }
}

public enum PaletteScope: Equatable {
    case everything
    case shortcuts
}

public enum RecordingOutcome: Equatable {
    case cancelled
    case cleared
    case ignored
    case rejected(KeyCombo, BindingProblem)
    case conflict(KeyCombo, [AppAction])
    case bound(KeyCombo)
}

private struct StoredBinding: Codable {
    let combo: KeyCombo?
}

@MainActor
public final class ShortcutStore: ObservableObject {
    public static let shared = ShortcutStore()

    @Published public private(set) var overrides: [AppAction: KeyCombo?] = [:]

    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "pith.shortcuts.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    public func combo(for action: AppAction) -> KeyCombo? {
        if let stored = overrides[action] {
            return stored
        }
        return action.defaultCombo
    }

    public func displayString(for action: AppAction) -> String? {
        combo(for: action)?.displayString
    }

    public func keycaps(for action: AppAction) -> [String] {
        combo(for: action)?.keycaps ?? []
    }

    public func isCustomized(_ action: AppAction) -> Bool {
        guard let stored = overrides[action] else { return false }
        return stored != action.defaultCombo
    }

    public var customizedCount: Int {
        AppAction.allCases.filter { isCustomized($0) }.count
    }

    public var hasAnyCustomizations: Bool {
        customizedCount > 0
    }

    public func conflicts(for candidate: KeyCombo, assigning action: AppAction) -> [AppAction] {
        AppAction.allCases.filter { other in
            guard other != action,
                  other.scope.overlaps(with: action.scope),
                  let existing = combo(for: other) else { return false }
            return existing == candidate
        }
    }

    public func problem(with candidate: KeyCombo, for action: AppAction) -> BindingProblem? {
        if candidate == action.defaultCombo {
            return nil
        }
        if !candidate.hasCommandLikeModifier {
            return .needsModifier
        }
        if let name = KeyCombo.systemReserved[candidate] {
            return .reservedBySystem(name)
        }
        return nil
    }

    public func set(_ newCombo: KeyCombo?, for action: AppAction, clearConflicts: Bool = false) {
        if clearConflicts, let newCombo {
            for conflict in conflicts(for: newCombo, assigning: action) {
                overrides[conflict] = .some(nil)
            }
        }
        if newCombo == action.defaultCombo {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = .some(newCombo)
        }
        save()
    }

    public func record(_ stroke: KeyStroke, for action: AppAction) -> RecordingOutcome {
        switch (stroke.key, stroke.modifiers) {
        case (.escape, []):
            return .cancelled
        case (.backspace, []), (.forwardDelete, []):
            set(nil, for: action)
            return .cleared
        default:
            break
        }
        guard let combo = KeyCombo(stroke: stroke) else { return .ignored }
        if let problem = problem(with: combo, for: action) {
            return .rejected(combo, problem)
        }
        let clashes = conflicts(for: combo, assigning: action)
        guard clashes.isEmpty else { return .conflict(combo, clashes) }
        set(combo, for: action)
        return .bound(combo)
    }

    public func reset(_ action: AppAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    public func resetAll() {
        overrides.removeAll()
        save()
    }

    public func action(matching stroke: KeyStroke, in scope: ShortcutScope) -> AppAction? {
        AppAction.allCases.first { action in
            action.scope == scope && combo(for: action)?.matches(stroke) == true
        }
    }

    public func actions(in category: ShortcutCategory?, matching query: String) -> [AppAction] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return AppAction.allCases.filter { action in
            if let category, action.category != category {
                return false
            }
            guard !words.isEmpty else { return true }
            let shortcutText = displayString(for: action)?.lowercased() ?? ""
            let haystack = "\(action.title) \(action.keywords) \(action.category.title) \(shortcutText)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    public func sections(matching query: String) -> [(category: ShortcutCategory, actions: [AppAction])] {
        let matches = actions(in: nil, matching: query)
        return ShortcutCategory.allCases.compactMap { category in
            let inCategory = matches.filter { $0.category == category }
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: StoredBinding].self, from: data) else {
            return
        }
        var loaded: [AppAction: KeyCombo?] = [:]
        for (raw, binding) in decoded {
            if let action = AppAction(rawValue: raw), binding.combo != action.defaultCombo {
                loaded[action] = .some(binding.combo)
            }
        }
        overrides = loaded
    }

    private func save() {
        var payload: [String: StoredBinding] = [:]
        for (action, combo) in overrides {
            payload[action.rawValue] = StoredBinding(combo: combo)
        }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

public enum BuiltInContext: String, CaseIterable, Identifiable {
    case writing
    case selection
    case allPages
    case palette

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .writing: return "While writing"
        case .selection: return "With blocks selected"
        case .allPages: return "All pages"
        case .palette: return "Command palette"
        }
    }
}

public struct BuiltInKey: Equatable, Identifiable {
    public let keycaps: [String]
    public let title: String
    public let context: BuiltInContext

    public var id: String { context.rawValue + title }

    public func matches(_ words: [Substring]) -> Bool {
        let haystack = (title + " " + context.title + " " + keycaps.joined(separator: " ")).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    public static let all: [BuiltInKey] = [
        BuiltInKey(keycaps: ["↵"], title: "Split block / new block", context: .writing),
        BuiltInKey(keycaps: ["⇧", "↵"], title: "New line inside the block", context: .writing),
        BuiltInKey(keycaps: ["⌫"], title: "Merge with the block above (at start)", context: .writing),
        BuiltInKey(keycaps: ["⇥"], title: "Indent", context: .writing),
        BuiltInKey(keycaps: ["⇧", "⇥"], title: "Outdent", context: .writing),
        BuiltInKey(keycaps: ["↑", "↓"], title: "Move between blocks", context: .writing),
        BuiltInKey(keycaps: ["⇧", "↑", "↓"], title: "Start selecting blocks", context: .writing),
        BuiltInKey(keycaps: ["esc"], title: "Select the current block", context: .writing),
        BuiltInKey(keycaps: ["[["], title: "Link a page", context: .writing),
        BuiltInKey(keycaps: ["#"], title: "Tag", context: .writing),
        BuiltInKey(keycaps: ["(("], title: "Reference a block", context: .writing),
        BuiltInKey(keycaps: ["/"], title: "Slash commands", context: .writing),
        BuiltInKey(keycaps: ["↑", "↓"], title: "Move the selection", context: .selection),
        BuiltInKey(keycaps: ["⇧", "↑", "↓"], title: "Extend the selection", context: .selection),
        BuiltInKey(keycaps: ["↵"], title: "Edit the selected block", context: .selection),
        BuiltInKey(keycaps: ["⌫"], title: "Delete selected blocks", context: .selection),
        BuiltInKey(keycaps: ["⇥", "⇧⇥"], title: "Indent / outdent selected blocks", context: .selection),
        BuiltInKey(keycaps: ["⌘", "C"], title: "Copy as Markdown", context: .selection),
        BuiltInKey(keycaps: ["⌘", "X"], title: "Cut as Markdown", context: .selection),
        BuiltInKey(keycaps: ["esc"], title: "Clear the selection", context: .selection),
        BuiltInKey(keycaps: ["/"], title: "Focus the filter", context: .allPages),
        BuiltInKey(keycaps: ["↑", "↓"], title: "Highlight a page", context: .allPages),
        BuiltInKey(keycaps: ["↵"], title: "Open the highlighted page", context: .allPages),
        BuiltInKey(keycaps: ["S"], title: "Star / unstar the highlighted page", context: .allPages),
        BuiltInKey(keycaps: ["R"], title: "Rename the highlighted page", context: .allPages),
        BuiltInKey(keycaps: ["⌘", "⌫"], title: "Delete the highlighted page", context: .allPages),
        BuiltInKey(keycaps: ["↑", "↓"], title: "Move through results", context: .palette),
        BuiltInKey(keycaps: ["↵"], title: "Open or run", context: .palette),
        BuiltInKey(keycaps: ["⌘", "↵"], title: "Change the selected command's shortcut", context: .palette),
        BuiltInKey(keycaps: ["⌫"], title: "Leave the shortcuts filter (empty search)", context: .palette),
        BuiltInKey(keycaps: ["esc"], title: "Close", context: .palette),
    ]

    public static func matching(_ query: String) -> [BuiltInKey] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return all.filter { $0.matches(words) }
    }
}
