import Foundation
import PithCore

public enum PageDirectoryTab: String, CaseIterable, Equatable {
    case pages = "Pages"
    case favorites = "Favorites"
    case journals = "Journals"
    case empty = "Empty"
    case all = "All"

    public func matches(_ summary: FfiPageSummary) -> Bool {
        switch self {
        case .pages:
            return summary.page.journalDay == nil
        case .favorites:
            return summary.page.favorite
        case .journals:
            return summary.page.journalDay != nil
        case .empty:
            return summary.page.journalDay == nil && summary.blockCount == 0
        case .all:
            return true
        }
    }
}

public enum PageDirectorySort: String, CaseIterable, Equatable {
    case updated = "Updated"
    case title = "A–Z"
    case backlinks = "Most linked"
    case blocks = "Most blocks"
}

public enum PageDirectory {
    public static func count(in summaries: [FfiPageSummary], for tab: PageDirectoryTab) -> Int {
        summaries.reduce(0) { $0 + (tab.matches($1) ? 1 : 0) }
    }

    public static func filter(
        _ summaries: [FfiPageSummary],
        tab: PageDirectoryTab,
        query: String,
        sort: PageDirectorySort
    ) -> [FfiPageSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = summaries.filter { summary in
            guard tab.matches(summary) else { return false }
            if needle.isEmpty { return true }
            return summary.page.title.lowercased().contains(needle)
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .updated:
                if lhs.page.updatedAt != rhs.page.updatedAt {
                    return lhs.page.updatedAt > rhs.page.updatedAt
                }
                return lhs.page.title.localizedCaseInsensitiveCompare(rhs.page.title) == .orderedAscending
            case .title:
                return lhs.page.title.localizedCaseInsensitiveCompare(rhs.page.title) == .orderedAscending
            case .backlinks:
                if lhs.backlinkCount != rhs.backlinkCount {
                    return lhs.backlinkCount > rhs.backlinkCount
                }
                if lhs.page.updatedAt != rhs.page.updatedAt {
                    return lhs.page.updatedAt > rhs.page.updatedAt
                }
                return lhs.page.title.localizedCaseInsensitiveCompare(rhs.page.title) == .orderedAscending
            case .blocks:
                if lhs.blockCount != rhs.blockCount {
                    return lhs.blockCount > rhs.blockCount
                }
                if lhs.page.updatedAt != rhs.page.updatedAt {
                    return lhs.page.updatedAt > rhs.page.updatedAt
                }
                return lhs.page.title.localizedCaseInsensitiveCompare(rhs.page.title) == .orderedAscending
            }
        }
    }

    public static func merge(_ library: PageLibrary, counts: [FfiPageSummary]) -> [FfiPageSummary] {
        let known = Dictionary(counts.map { ($0.page.id, $0) }, uniquingKeysWith: { _, newer in newer })
        return library.byId.values.map { page in
            FfiPageSummary(
                page: page,
                blockCount: known[page.id]?.blockCount ?? 0,
                backlinkCount: known[page.id]?.backlinkCount ?? 0
            )
        }
    }

    public static func offersCreate(query: String, in summaries: [FfiPageSummary]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !summaries.contains { $0.page.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

public struct PageDirectoryLayout: Equatable {
    public let stacksHeader: Bool
    public let compactSort: Bool
    public let showsCounts: Bool
    public let updatedInColumn: Bool

    public init(stacksHeader: Bool, compactSort: Bool, showsCounts: Bool, updatedInColumn: Bool) {
        self.stacksHeader = stacksHeader
        self.compactSort = compactSort
        self.showsCounts = showsCounts
        self.updatedInColumn = updatedInColumn
    }

    public init(width: CGFloat) {
        self.init(
            stacksHeader: width < 520,
            compactSort: width < 560,
            showsCounts: width >= 430,
            updatedInColumn: width >= 300
        )
    }
}
