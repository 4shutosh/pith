import CoreGraphics
import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class PaletteResultsTests: XCTestCase {
    private func page(_ id: String, _ title: String, score: UInt32, journal: Bool = false, links: UInt32 = 0) -> FfiSearchHit {
        .page(pageId: id, title: title, highlightedTitle: [FfiSegment(text: title, highlighted: false)], journalDay: journal ? 20261125 : nil, backlinkCount: links, score: score)
    }

    private func block(_ id: String, on pageId: String, score: UInt32) -> FfiSearchHit {
        .block(blockId: id, pageId: pageId, pageTitle: "Page \(pageId)", pageJournalDay: nil, breadcrumb: ["Page \(pageId)"], snippet: [FfiSegment(text: id, highlighted: false)], cursor: 0, score: score)
    }

    private func command(_ action: AppAction, _ score: UInt32) -> ScoredCommand {
        ScoredCommand(item: PaletteItem(action: action, title: action.title, shortcut: nil), score: score)
    }

    private var hits: [FfiSearchHit] {
        [
            page("P1", "Habit stacking", score: 101),
            block("b1", on: "A", score: 86),
            page("P2", "Atomic Habits", score: 83),
            block("b2", on: "A", score: 66),
            block("b3", on: "A", score: 66),
            block("b4", on: "B", score: 66),
            block("b5", on: "A", score: 26),
        ]
    }

    private var commands: [ScoredCommand] {
        [command(.openSettings, 35), command(.goBack, 20), command(.toggleTheme, 75), command(.toggleSidebar, 30)]
    }

    private func ids(_ results: PaletteResults) -> [String] {
        results.rows.map(\.id)
    }

    func testAllIsOneRankedListWithCommandsInterleavedAndAtMostTwoBlocksPerPage() {
        let results = PaletteResults.build(query: "habit", filter: .all, hits: hits, commands: commands, recents: [], expanded: [])
        XCTAssertEqual(ids(results), [
            "page:P1",
            "block:b1:0",
            "page:P2",
            "command:toggleTheme",
            "block:b2:0",
            "more:A",
            "block:b4:0",
            "command:openSettings",
            "command:toggleSidebar",
            "create",
        ])
        guard case let .more(_, _, hidden) = results.rows[5].kind else { return XCTFail("expected the more row") }
        XCTAssertEqual(hidden.map(\.id), ["b3", "b5"])
        XCTAssertEqual(results.count(.all), 11)
        XCTAssertEqual(results.count(.pages), 2)
        XCTAssertEqual(results.count(.blocks), 5)
        XCTAssertEqual(results.count(.commands), 4)
    }

    func testExpandingAPageShowsAllItsBlocksInRankOrder() {
        let results = PaletteResults.build(query: "habit", filter: .all, hits: hits, commands: commands, recents: [], expanded: ["A"])
        XCTAssertEqual(ids(results), [
            "page:P1",
            "block:b1:0",
            "page:P2",
            "command:toggleTheme",
            "block:b2:0",
            "block:b3:0",
            "block:b4:0",
            "command:openSettings",
            "command:toggleSidebar",
            "block:b5:0",
            "create",
        ])
    }

    func testFiltersShowOnlyTheirKind() {
        XCTAssertEqual(
            ids(PaletteResults.build(query: "habit", filter: .pages, hits: hits, commands: commands, recents: [], expanded: [])),
            ["page:P1", "page:P2", "create"]
        )
        XCTAssertEqual(
            ids(PaletteResults.build(query: "habit", filter: .blocks, hits: hits, commands: commands, recents: [], expanded: [])),
            ["block:b1:0", "block:b2:0", "more:A", "block:b4:0"]
        )
        XCTAssertEqual(
            ids(PaletteResults.build(query: "habit", filter: .commands, hits: hits, commands: commands, recents: [], expanded: [])),
            ["command:toggleTheme", "command:openSettings", "command:toggleSidebar", "command:goBack"]
        )
    }

    func testAnExactTitleMatchHidesCreate() {
        let results = PaletteResults.build(query: "atomic HABITS", filter: .all, hits: hits, commands: [], recents: [], expanded: [])
        XCTAssertFalse(ids(results).contains("create"))
    }

    func testAnEmptyQueryShowsRecentPagesThenCommands() {
        let recents = (1...8).map { FfiPage(id: "r\($0)", title: "Recent \($0)", journalDay: $0 == 1 ? 20261128 : nil, documentMode: false, favorite: false, version: 1, updatedAt: 0) }
        let results = PaletteResults.build(query: "", filter: .all, hits: [], commands: [command(.toggleTheme, 0)], recents: recents, expanded: [])
        XCTAssertEqual(ids(results), ["page:r1", "page:r2", "page:r3", "page:r4", "page:r5", "page:r6", "command:toggleTheme"])
        XCTAssertEqual(results.rows.map(\.section), ["Recent", "Recent", "Recent", "Recent", "Recent", "Recent", "Commands"])
        guard case let .page(first) = results.rows[0].kind else { return XCTFail("expected a page row") }
        XCTAssertTrue(first.isJournal)
        XCTAssertEqual(results.count(.all), nil)
        XCTAssertEqual(ids(PaletteResults.build(query: "", filter: .pages, hits: [], commands: [], recents: recents, expanded: [])).count, 8)
        XCTAssertEqual(PaletteResults.build(query: "", filter: .blocks, hits: [], commands: [], recents: recents, expanded: []), .empty)
    }

    func testAGreaterThanPrefixSearchesCommandsAndTabCyclesFilters() {
        XCTAssertEqual(PaletteQuery(">  dark ").text, "dark")
        XCTAssertTrue(PaletteQuery(">dark").forcesCommands)
        XCTAssertFalse(PaletteQuery("dark > light").forcesCommands)
        XCTAssertEqual(PaletteFilter.all.next, .pages)
        XCTAssertEqual(PaletteFilter.commands.next, .all)
        XCTAssertEqual(PaletteFilter.all.previous, .commands)
    }

    func testThePreviewSitsBesideTheListOnlyWhenThePaletteIsWide() {
        let cases: [(CGSize, CGFloat, CGFloat, Bool)] = [
            (CGSize(width: 1280, height: 800), 960, 560, true),
            (CGSize(width: 792, height: 700), 760, 560, true),
            (CGSize(width: 791, height: 700), 759, 560, false),
            (CGSize(width: 520, height: 700), 488, 560, false),
            (CGSize(width: 380, height: 420), 348, 358, false),
            (CGSize(width: 380, height: 300), 348, 280, false),
        ]
        for (container, width, height, side) in cases {
            let layout = PaletteLayout(container: container)
            XCTAssertEqual(layout.width, width, "width in \(container)")
            XCTAssertEqual(layout.height, height, "height in \(container)")
            XCTAssertEqual(layout.showsSidePreview, side, "side preview in \(container)")
        }
    }

    func testKeyHintsThatDoNotFitAreDroppedRatherThanWrapped() {
        XCTAssertTrue(PaletteLayout(container: CGSize(width: 520, height: 700)).showsAllHints)
        XCTAssertTrue(PaletteLayout(container: CGSize(width: 472, height: 700)).showsAllHints)
        XCTAssertFalse(PaletteLayout(container: CGSize(width: 471, height: 700)).showsAllHints)
        XCTAssertFalse(PaletteLayout(container: CGSize(width: 380, height: 700)).showsAllHints)
    }

    func testJournalPagesUseTheChosenDateFormatEverywhereInResults() {
        let journal = PaletteResults.build(
            query: "plan",
            filter: .all,
            hits: [.block(blockId: "b", pageId: "j", pageTitle: "2026-11-25", pageJournalDay: 20261125, breadcrumb: ["2026-11-25", "Work"], snippet: [], cursor: 0, score: 60)],
            commands: [],
            recents: [],
            expanded: []
        )
        guard case let .block(block) = journal.rows[0].kind else { return XCTFail("expected a block row") }
        XCTAssertEqual(SearchPresentation.crumbs(of: block, format: .medium), "Nov 25, 2026 / Work")
        XCTAssertEqual(SearchPresentation.crumbs(of: block, format: .iso), "2026-11-25 / Work")
        XCTAssertEqual(SearchPresentation.previewTitle(journal.rows[0].kind, format: .weekday), "Wed, Nov 25, 2026")
        XCTAssertEqual(SearchPresentation.displayTitle("2026-11-25", isJournal: false, format: .medium), "2026-11-25")
    }

    func testPageRowsNameJournalsAndLinkCounts() {
        XCTAssertEqual(SearchPresentation.pageAccessory(isJournal: true, backlinks: 9), "Journal")
        XCTAssertEqual(SearchPresentation.pageAccessory(isJournal: false, backlinks: 0), nil)
        XCTAssertEqual(SearchPresentation.pageAccessory(isJournal: false, backlinks: nil), nil)
        XCTAssertEqual(SearchPresentation.pageAccessory(isJournal: false, backlinks: 1), "1 link")
        XCTAssertEqual(SearchPresentation.pageAccessory(isJournal: false, backlinks: 4), "4 links")
    }

    func testCommandsAreScoredByTheCoreRanking() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory())
        let dark = controller.paletteCommands(matching: "dark")
        XCTAssertEqual(dark.first, ScoredCommand(item: PaletteItem(action: .toggleTheme, title: "Toggle Light / Dark", shortcut: controller.paletteItems.first { $0.action == .toggleTheme }?.shortcut), score: 75))
        XCTAssertEqual(controller.paletteCommands(matching: "").count, controller.paletteItems.count)
        XCTAssertTrue(controller.paletteCommands(matching: "").allSatisfy { $0.score == 0 })
    }

    func testThePaletteKeysAreListedForTheShortcutsPage() {
        let keys = BuiltInKey.all.filter { $0.context == .palette }.map(\.keycaps)
        XCTAssertTrue(keys.contains(["⇥"]))
        XCTAssertTrue(keys.contains(["⇧", "⇥"]))
        XCTAssertTrue(keys.contains([">"]))
    }
}
