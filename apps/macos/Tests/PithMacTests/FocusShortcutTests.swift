import PithCore
import PithMacCore
import XCTest

@MainActor
final class FocusShortcutTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    private func seedToday(_ graph: PithGraph, _ texts: [String]) throws -> [String] {
        let outcome = try graph.startJournal(date: nil, meta: setup)
        let pageId = try XCTUnwrap(graph.journalPage(date: nil)).id
        var ids = [outcome.focusBlockId]
        var ops: [FfiOp] = [.updateBlock(id: outcome.focusBlockId, content: texts[0], expectedVersion: nil)]
        var key = try XCTUnwrap(graph.readPageWindow(pageId: pageId, offset: 0, limit: 10).rows.last).orderKey
        for text in texts.dropFirst() {
            key = try orderKeyBetween(lower: key, upper: nil)
            let id = newId()
            ids.append(id)
            ops.append(.insertBlock(id: id, pageId: pageId, parentId: nil, orderKey: key, content: text))
        }
        _ = try graph.applyOps(ops: ops, meta: setup)
        return ids
    }

    func testGoToTodayOpensTheStreamWithTheCaretAtTheEndOfToday() throws {
        let graph = try PithGraph.openInMemory()
        let ids = try seedToday(graph, ["first", "second"])
        let controller = try OutlinerController(graph: graph)
        controller.openPageByTitle("Roadmap")

        controller.perform(.goToToday)
        XCTAssertTrue(controller.isJournalStream)
        XCTAssertEqual(controller.focusedBlockId, ids[1])
        XCTAssertEqual(controller.requestedCursorOffset, 6)
    }

    func testGoToTodayStartsTheFirstBlockWhenTodayIsEmpty() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory())
        controller.openPageByTitle("Roadmap")
        controller.perform(.goToToday)
        XCTAssertTrue(controller.isJournalStream)
        XCTAssertNotNil(controller.focusedBlockId)
        XCTAssertEqual(controller.rows.map(\.renderedContent), [""])
    }

    func testFocusEditorReturnsToTheLastEditedBlockOrTheEndOfThePage() throws {
        let graph = try PithGraph.openInMemory()
        let ids = try seedToday(graph, ["alpha", "beta", "gamma"])
        let controller = try OutlinerController(graph: graph)

        controller.focusEditor()
        XCTAssertEqual(controller.focusedBlockId, ids[2])
        XCTAssertEqual(controller.requestedCursorOffset, 5)

        controller.focusBlock(ids[0], cursorOffset: 1)
        controller.blurFocus()
        XCTAssertNil(controller.focusedBlockId)
        controller.perform(.focusEditor)
        XCTAssertEqual(controller.focusedBlockId, ids[0])
        XCTAssertEqual(controller.requestedCursorOffset, 5)

        controller.focusBlock(ids[1], cursorOffset: 2)
        controller.focusEditor()
        XCTAssertEqual(controller.focusedBlockId, ids[1])
        XCTAssertEqual(controller.requestedCursorOffset, 2)
    }

    func testFocusEditorIsUnavailableOnListScreens() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory())
        controller.showAllPages()
        XCTAssertFalse(controller.isAvailable(.focusEditor))
        XCTAssertTrue(controller.isAvailable(.goToToday))
    }
}
