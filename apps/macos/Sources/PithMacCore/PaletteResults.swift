import Foundation
import PithCore

public enum PaletteFilter: CaseIterable, Equatable {
    case all
    case pages
    case blocks
    case commands

    public var title: String {
        switch self {
        case .all: return "All"
        case .pages: return "Pages"
        case .blocks: return "Blocks"
        case .commands: return "Commands"
        }
    }

    public var next: PaletteFilter {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    public var previous: PaletteFilter {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + all.count - 1) % all.count]
    }
}

public struct PaletteQuery: Equatable {
    public let text: String
    public let forcesCommands: Bool

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(">") {
            text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            forcesCommands = true
        } else {
            text = trimmed
            forcesCommands = false
        }
    }
}

public struct ScoredCommand: Equatable {
    public let item: PaletteItem
    public let score: UInt32

    public init(item: PaletteItem, score: UInt32) {
        self.item = item
        self.score = score
    }
}

public struct PalettePage: Equatable {
    public let id: String
    public let title: String
    public let highlighted: [FfiSegment]
    public let isJournal: Bool
    public let backlinkCount: UInt32?
}

public struct PaletteBlock: Equatable {
    public let id: String
    public let pageId: String
    public let pageTitle: String
    public let pageIsJournal: Bool
    public let crumbs: [String]
    public let snippet: [FfiSegment]
    public let cursor: UInt32
}

public enum PaletteRowKind: Equatable {
    case page(PalettePage)
    case block(PaletteBlock)
    case command(PaletteItem)
    case more(pageId: String, pageTitle: String, hidden: [PaletteBlock])
    case create(title: String)
}

public struct PaletteRow: Identifiable, Equatable {
    public let id: String
    public let kind: PaletteRowKind
    public let section: String?

    init(_ kind: PaletteRowKind, section: String? = nil) {
        self.kind = kind
        self.section = section
        switch kind {
        case let .page(page): id = "page:\(page.id)"
        case let .block(block): id = "block:\(block.id):\(block.cursor)"
        case let .command(item): id = "command:\(item.action)"
        case let .more(pageId, _, _): id = "more:\(pageId)"
        case .create: id = "create"
        }
    }

    public static func id(for block: PaletteBlock) -> String {
        PaletteRow(.block(block)).id
    }
}

public enum PalettePreview: Equatable {
    case page(FfiLinkPreview)
    case block(FfiBlockContext)
}

public struct PaletteResults: Equatable {
    public static let blocksPerPage = 2
    public static let commandsInAll = 3
    public static let recentsInAll = 6

    public let rows: [PaletteRow]
    public let counts: [PaletteFilter: Int]

    public static let empty = PaletteResults(rows: [], counts: [:])

    public func count(_ filter: PaletteFilter) -> Int? {
        counts[filter]
    }

    public static func build(
        query: String,
        filter: PaletteFilter,
        hits: [FfiSearchHit],
        commands: [ScoredCommand],
        recents: [FfiPage],
        expanded: Set<String>
    ) -> PaletteResults {
        guard !query.isEmpty else {
            return emptyQuery(filter: filter, commands: commands, recents: recents)
        }
        let pages = hits.compactMap(page(from:))
        let blocks = hits.compactMap(block(from:))
        let rankedCommands = commands.sorted { $0.score > $1.score }
        let counts: [PaletteFilter: Int] = [
            .all: pages.count + blocks.count + rankedCommands.count,
            .pages: pages.count,
            .blocks: blocks.count,
            .commands: rankedCommands.count,
        ]
        let createRow = offersCreate(query: query, pages: pages) ? [PaletteRow(.create(title: query))] : []

        switch filter {
        case .pages:
            return PaletteResults(rows: pages.map { PaletteRow(.page($0.page)) } + createRow, counts: counts)
        case .blocks:
            var cap = BlockCap(blocks: blocks.map(\.block), expanded: expanded)
            return PaletteResults(rows: blocks.flatMap { cap.rows(for: $0.block) }, counts: counts)
        case .commands:
            return PaletteResults(rows: rankedCommands.map { PaletteRow(.command($0.item)) }, counts: counts)
        case .all:
            var merged: [PaletteRow] = []
            var cap = BlockCap(blocks: blocks.map(\.block), expanded: expanded)
            var commandQueue = Array(rankedCommands.prefix(commandsInAll))
            for hit in hits {
                let score = hit.paletteScore
                while let next = commandQueue.first, next.score > score {
                    merged.append(PaletteRow(.command(next.item)))
                    commandQueue.removeFirst()
                }
                if let page = page(from: hit) {
                    merged.append(PaletteRow(.page(page.page)))
                } else if let block = block(from: hit)?.block {
                    merged += cap.rows(for: block)
                }
            }
            merged += commandQueue.map { PaletteRow(.command($0.item)) }
            return PaletteResults(rows: merged + createRow, counts: counts)
        }
    }

    private static func emptyQuery(filter: PaletteFilter, commands: [ScoredCommand], recents: [FfiPage]) -> PaletteResults {
        let recentRows = recents.map { page in
            PaletteRow(
                .page(PalettePage(
                    id: page.id,
                    title: page.title,
                    highlighted: [FfiSegment(text: page.title, highlighted: false)],
                    isJournal: page.journalDay != nil,
                    backlinkCount: nil
                )),
                section: "Recent"
            )
        }
        let commandRows = commands.map { PaletteRow(.command($0.item), section: "Commands") }
        switch filter {
        case .all:
            return PaletteResults(rows: Array(recentRows.prefix(recentsInAll)) + commandRows, counts: [:])
        case .pages:
            return PaletteResults(rows: recentRows, counts: [:])
        case .blocks:
            return .empty
        case .commands:
            return PaletteResults(rows: commands.map { PaletteRow(.command($0.item)) }, counts: [:])
        }
    }

    private static func offersCreate(query: String, pages: [(page: PalettePage, score: UInt32)]) -> Bool {
        !pages.contains { $0.page.title.caseInsensitiveCompare(query) == .orderedSame }
    }

    private static func page(from hit: FfiSearchHit) -> (page: PalettePage, score: UInt32)? {
        guard case let .page(pageId, title, highlightedTitle, journalDay, backlinkCount, score) = hit else { return nil }
        return (PalettePage(id: pageId, title: title, highlighted: highlightedTitle, isJournal: journalDay != nil, backlinkCount: backlinkCount), score)
    }

    private static func block(from hit: FfiSearchHit) -> (block: PaletteBlock, score: UInt32)? {
        guard case let .block(blockId, pageId, pageTitle, pageJournalDay, breadcrumb, snippet, cursor, score) = hit else { return nil }
        return (PaletteBlock(id: blockId, pageId: pageId, pageTitle: pageTitle, pageIsJournal: pageJournalDay != nil, crumbs: breadcrumb, snippet: snippet, cursor: cursor), score)
    }
}

private struct BlockCap {
    let byPage: [String: [PaletteBlock]]
    let expanded: Set<String>
    var shown: [String: Int] = [:]

    init(blocks: [PaletteBlock], expanded: Set<String>) {
        byPage = Dictionary(grouping: blocks, by: \.pageId)
        self.expanded = expanded
    }

    mutating func rows(for block: PaletteBlock) -> [PaletteRow] {
        let count = shown[block.pageId, default: 0]
        let isExpanded = expanded.contains(block.pageId)
        guard count < PaletteResults.blocksPerPage || isExpanded else { return [] }
        shown[block.pageId] = count + 1
        let siblings = byPage[block.pageId] ?? []
        guard !isExpanded, count + 1 == PaletteResults.blocksPerPage, siblings.count > PaletteResults.blocksPerPage else {
            return [PaletteRow(.block(block))]
        }
        let hidden = Array(siblings.dropFirst(PaletteResults.blocksPerPage))
        return [PaletteRow(.block(block)), PaletteRow(.more(pageId: block.pageId, pageTitle: block.pageTitle, hidden: hidden))]
    }
}

extension FfiSearchHit {
    var paletteScore: UInt32 {
        switch self {
        case let .page(_, _, _, _, _, score): return score
        case let .block(_, _, _, _, _, _, _, score): return score
        }
    }
}

public struct PaletteLayout: Equatable {
    public static let maximumWidth: CGFloat = 960
    public static let maximumHeight: CGFloat = 560
    public static let minimumHeight: CGFloat = 280
    public static let sidePreviewWidth: CGFloat = 760
    public static let listWidth: CGFloat = 400
    public static let margin: CGFloat = 16
    public static let top: CGFloat = 46

    public static let allHintsWidth: CGFloat = 440

    public let width: CGFloat
    public let height: CGFloat
    public let showsSidePreview: Bool
    public let showsAllHints: Bool

    public init(container: CGSize) {
        width = max(0, min(Self.maximumWidth, container.width - 2 * Self.margin))
        height = max(Self.minimumHeight, min(Self.maximumHeight, container.height - Self.top - Self.margin))
        showsSidePreview = width >= Self.sidePreviewWidth
        showsAllHints = width >= Self.allHintsWidth
    }
}
