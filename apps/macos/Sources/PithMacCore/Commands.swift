public struct PaletteItem: Equatable {
    public let action: AppAction
    public let title: String
    public let shortcut: String?

    public init(action: AppAction, title: String, shortcut: String?) {
        self.action = action
        self.title = title
        self.shortcut = shortcut
    }
}
