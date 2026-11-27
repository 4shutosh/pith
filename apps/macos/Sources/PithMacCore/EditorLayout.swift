import CoreGraphics

public struct EditorLayout: Equatable {
    public static let sidebarWidth: CGFloat = 216
    public static let minimumSideMargin: CGFloat = 64
    public static let compactSideMargin: CGFloat = 24
    public static let maximumContentWidth: CGFloat = 680
    public static let directoryWidth: CGFloat = 820
    public static let minimumContentWidth: CGFloat = 320
    public static let minimumWindowWidth: CGFloat = 360
    public static let minimumWindowHeight: CGFloat = 400

    public let leading: CGFloat
    public let width: CGFloat

    public init(leading: CGFloat, width: CGFloat) {
        self.leading = leading
        self.width = width
    }

    public static func sidebarDocks(windowWidth: CGFloat) -> Bool {
        windowWidth - (sidebarWidth + 1) >= minimumContentWidth + 2 * compactSideMargin
    }

    public static func compute(
        windowWidth: CGFloat,
        sidebarOpen: Bool,
        maximumWidth: CGFloat = maximumContentWidth
    ) -> EditorLayout {
        let docked = sidebarOpen && sidebarDocks(windowWidth: windowWidth)
        let sidebar: CGFloat = docked ? sidebarWidth + 1 : 0
        let pane = windowWidth - sidebar
        let margin = max(compactSideMargin, min(minimumSideMargin, (pane - minimumContentWidth) / 2))
        let width = min(maximumWidth, max(0, pane - 2 * margin))
        let leading = sidebar + max(margin, (pane - width) / 2)
        return EditorLayout(leading: leading, width: width)
    }
}
