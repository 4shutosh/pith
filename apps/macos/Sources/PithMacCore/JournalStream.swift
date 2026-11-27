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

public struct EarlierRowsAnchor: Equatable {
    public let blockId: String
    public let seq: UInt64
}
