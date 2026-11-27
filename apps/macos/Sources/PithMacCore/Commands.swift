public struct PaletteItem: Equatable {
    public let action: AppAction
    public let title: String
    public let shortcut: String?

    public init(action: AppAction, title: String, shortcut: String?) {
        self.action = action
        self.title = title
        self.shortcut = shortcut
    }

    func matches(_ words: [Substring]) -> Bool {
        let haystack = (title + " " + action.keywords).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}
