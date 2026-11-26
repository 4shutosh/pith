import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class JournalStreamTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    private func seedJournal(_ graph: PithGraph, _ date: String, _ texts: [String]) throws {
        let outcome = try graph.startJournal(date: date, meta: setup)
        let pageId = try XCTUnwrap(graph.journalPage(date: date)).id
        var ops: [FfiOp] = [.updateBlock(id: outcome.focusBlockId, content: texts[0], expectedVersion: nil)]
        var key = try XCTUnwrap(graph.readPageWindow(pageId: pageId, offset: 0, limit: 10).rows.last).orderKey
        for text in texts.dropFirst() {
            key = try orderKeyBetween(lower: key, upper: nil)
            ops.append(.insertBlock(id: newId(), pageId: pageId, parentId: nil, orderKey: key, content: text))
        }
        _ = try graph.applyOps(ops: ops, meta: setup)
    }

    private func makeController(_ graph: PithGraph) throws -> OutlinerController {
        let controller = try OutlinerController(graph: graph)
        controller.debounceNanoseconds = 60_000_000_000
        return controller
    }

    func testTheStreamShowsTodayThenPastDaysWithContentNewestFirst() throws {
        let graph = try PithGraph.openInMemory()
        try seedJournal(graph, "2020-01-02", ["older"])
        try seedJournal(graph, "2020-01-03", ["newer one", "newer two"])
        try seedJournal(graph, "2999-01-01", ["future"])
        _ = try graph.applyOps(
            ops: [.createPage(id: newId(), title: "2020-01-04", journalDay: 20200104, documentMode: false)],
            meta: setup
        )

        let controller = try makeController(graph)
        XCTAssertTrue(controller.isJournalStream)
        XCTAssertEqual(controller.journalSections.map(\.title), [controller.todayTitle, "2020-01-03", "2020-01-02"])
        XCTAssertEqual(controller.journalSections.map(\.rowRange), [0..<0, 0..<2, 2..<3])
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["newer one", "newer two", "older"])
        XCTAssertFalse(controller.hasMoreRows)
    }

    func testEditingMovesAcrossDaysButSelectionStaysWithinOneDay() throws {
        let graph = try PithGraph.openInMemory()
        try seedJournal(graph, "2020-01-02", ["older"])
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        controller.updateDraft(blockId: try XCTUnwrap(controller.focusedBlockId), text: "today", isComposing: false)
        controller.flushDraft()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["today", "older"])

        controller.moveFocusDown(column: 0)
        XCTAssertEqual(controller.focusedBlockId, controller.rows[1].id)

        controller.moveFocusUp(column: 0)
        controller.extendSelection(up: false)
        XCTAssertEqual(controller.selectedBlockIds, [controller.rows[0].id])
    }

    func testZoomingIntoAPastDayOpensThatPageAndBackReturnsToTheStream() throws {
        let graph = try PithGraph.openInMemory()
        try seedJournal(graph, "2020-01-02", ["older"])
        let controller = try makeController(graph)
        let older = try XCTUnwrap(controller.rows.first)

        controller.zoom(into: older.id)
        XCTAssertFalse(controller.isJournalStream)
        XCTAssertEqual(controller.selectedPageId, older.pageId)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["older"])

        controller.goBack()
        XCTAssertTrue(controller.isJournalStream)
        XCTAssertNil(controller.zoomedBlockId)
        XCTAssertEqual(controller.journalSections.map(\.title), [controller.todayTitle, "2020-01-02"])
    }

    func testOlderDaysLoadSevenAtATime() throws {
        let graph = try PithGraph.openInMemory()
        for day in 1...9 {
            try seedJournal(graph, String(format: "2020-01-%02d", day), ["day \(day)"])
        }
        let controller = try makeController(graph)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["day 9", "day 8", "day 7", "day 6", "day 5", "day 4", "day 3"])
        XCTAssertTrue(controller.hasOlderJournals)

        controller.loadOlderJournals()
        XCTAssertEqual(controller.rows.count, 9)
        XCTAssertEqual(controller.rows.last?.renderedContent, "day 1")
        XCTAssertFalse(controller.hasOlderJournals)
    }

    func testOpeningOneDayLeavesTheStream() throws {
        let graph = try PithGraph.openInMemory()
        try seedJournal(graph, "2020-01-02", ["older"])
        let controller = try makeController(graph)
        controller.openJournal(date: "2020-01-02")
        XCTAssertFalse(controller.isJournalStream)
        XCTAssertEqual(controller.pageTitle, "2020-01-02")
        XCTAssertEqual(controller.journalSections, [])

        controller.openTodayJournal()
        XCTAssertTrue(controller.isJournalStream)

        controller.openJournal(date: controller.todayTitle)
        XCTAssertFalse(controller.isJournalStream)
        XCTAssertEqual(controller.journalSections, [])
        XCTAssertEqual(controller.rows.map(\.renderedContent), [])

        controller.goBack()
        XCTAssertTrue(controller.isJournalStream)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["older"])
    }
}
