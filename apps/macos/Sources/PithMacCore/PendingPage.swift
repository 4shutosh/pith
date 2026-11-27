import Foundation

public enum PendingPage: Equatable {
    case journal(date: String)
    case untitled(title: String)

    public var title: String {
        switch self {
        case let .journal(date): return date
        case let .untitled(title): return title
        }
    }
}

public struct DisplayedView: Equatable {
    public let listScreen: ListScreen?
    public let isJournalStream: Bool
    public let pageId: String?
    public let zoomedBlockId: String?
    public let pendingPage: PendingPage?
}
