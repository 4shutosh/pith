public struct JournalSection: Equatable {
    public let pageId: String?
    public let title: String
    public let rowRange: Range<Int>

    public init(pageId: String?, title: String, rowRange: Range<Int>) {
        self.pageId = pageId
        self.title = title
        self.rowRange = rowRange
    }
}
