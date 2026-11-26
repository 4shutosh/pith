import CoreGraphics

public struct EditorLayout: Equatable {
    public static let sidebarWidth: CGFloat = 216
    public static let minimumSideMargin: CGFloat = 64
    public static let maximumContentWidth: CGFloat = 680
    public static let directoryWidth: CGFloat = 820
    public static let minimumContentWidth: CGFloat = 320

    public let leading: CGFloat
    public let width: CGFloat

    public init(leading: CGFloat, width: CGFloat) {
        self.leading = leading
        self.width = width
    }

    public static func compute(
        windowWidth: CGFloat,
        sidebarOpen: Bool,
        maximumWidth: CGFloat = maximumContentWidth
    ) -> EditorLayout {
        let sidebar: CGFloat = sidebarOpen ? sidebarWidth + 1 : 0
        let pane = windowWidth - sidebar
        let width = min(maximumWidth, max(minimumContentWidth, pane - 2 * minimumSideMargin))
        let leading = sidebar + max(minimumSideMargin, (pane - width) / 2)
        return EditorLayout(leading: leading, width: width)
    }
}
