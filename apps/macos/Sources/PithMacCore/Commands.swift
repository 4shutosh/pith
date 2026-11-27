public enum PaletteCommand: String, CaseIterable, Equatable {
    case findInPage
    case expandAll
    case collapseAll
    case toggleFavorite
    case renamePage
    case deletePage
    case openJournals
    case previousDay
    case nextDay
    case allPages
    case goBack
    case goForward
    case toggleSidebar
    case toggleTheme

    public var shortcut: String? {
        switch self {
        case .findInPage: return "⌘F"
        case .expandAll: return "⌥⌘."
        case .collapseAll: return "⇧⌘."
        case .toggleFavorite: return "⌘D"
        case .renamePage: return "⇧⌘R"
        case .deletePage: return nil
        case .openJournals: return "⌘J"
        case .previousDay: return "⌥⌘["
        case .nextDay: return "⌥⌘]"
        case .allPages: return "⇧⌘P"
        case .goBack: return "⌘["
        case .goForward: return "⌘]"
        case .toggleSidebar: return "⌘\\"
        case .toggleTheme: return "⇧⌘L"
        }
    }

    var keywords: String {
        switch self {
        case .findInPage: return "find search page text highlight"
        case .expandAll: return "expand unfold open all blocks children"
        case .collapseAll: return "collapse fold close all blocks children"
        case .toggleFavorite: return "favorite star pin bookmark"
        case .renamePage: return "rename title page"
        case .deletePage: return "delete remove trash page"
        case .openJournals: return "journals today daily"
        case .previousDay: return "previous yesterday day journal back"
        case .nextDay: return "next tomorrow day journal forward"
        case .allPages: return "all pages directory list"
        case .goBack: return "back history"
        case .goForward: return "forward history"
        case .toggleSidebar: return "sidebar hide show"
        case .toggleTheme: return "theme dark light appearance"
        }
    }
}

public struct PaletteItem: Equatable {
    public let command: PaletteCommand
    public let title: String

    public init(command: PaletteCommand, title: String) {
        self.command = command
        self.title = title
    }

    public var shortcut: String? { command.shortcut }

    func matches(_ words: [Substring]) -> Bool {
        let haystack = (title + " " + command.keywords).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}
