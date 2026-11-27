import PithCore
import PithMacCore
import XCTest

@MainActor
final class WindowTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    private func longPage(_ graph: PithGraph, lines: Int) throws -> (page: String, blocks: [String]) {
        let pageId = newId()
        var ops: [FfiOp] = [.createPage(id: pageId, title: "Long", journalDay: nil, documentMode: false)]
        var ids: [String] = []
        var key: String?
        for n in 0..<lines {
            let next = try orderKeyBetween(lower: key, upper: nil)
            let id = newId()
            ops.append(.insertBlock(id: id, pageId: pageId, parentId: nil, orderKey: next, content: "line \(n)"))
            ids.append(id)
            key = next
        }
        _ = try graph.applyOps(ops: ops, meta: setup)
        return (pageId, ids)
    }

    func testRowsAboveADeepJumpLoadInPagesKeepingTheirPlace() throws {
        let graph = try PithGraph.openInMemory()
        let long = try longPage(graph, lines: 1200)
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(long.page)

        controller.openBlock(id: long.blocks[1100])
        XCTAssertEqual(controller.focusedBlockId, long.blocks[1100])
        XCTAssertEqual(controller.rows.first?.renderedContent, "line 850")
        XCTAssertEqual(controller.rows.last?.renderedContent, "line 1199")
        XCTAssertEqual(controller.rows.count, 350)
        XCTAssertEqual(controller.rowsAbove, 850)
        XCTAssertEqual(controller.rowsBelow, 0)
        XCTAssertFalse(controller.hasMoreRows)
        XCTAssertTrue(controller.hasEarlierRows)

        controller.loadEarlierRows()
        XCTAssertEqual(controller.rows.first?.renderedContent, "line 350")
        XCTAssertEqual(controller.rows.count, 850)
        XCTAssertEqual(controller.rowsAbove, 350)
        XCTAssertEqual(controller.earlierRowsAnchor?.blockId, long.blocks[850])
        XCTAssertEqual(controller.focusedBlockId, long.blocks[1100])

        controller.loadEarlierRows()
        XCTAssertEqual(controller.rows.map(\.renderedContent), (0..<1200).map { "line \($0)" })
        XCTAssertFalse(controller.hasEarlierRows)
        XCTAssertEqual(controller.earlierRowsAnchor?.blockId, long.blocks[350])
    }

    func testAStructuralChangeKeepsEveryLoadedRow() throws {
        let graph = try PithGraph.openInMemory()
        let long = try longPage(graph, lines: 1200)
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(long.page)
        controller.openBlock(id: long.blocks[1100])
        controller.blurFocus()
        controller.loadEarlierRows()

        _ = try graph.applyOps(ops: [.deleteBlock(id: long.blocks[900], expectedVersion: nil)], meta: setup)
        controller.applyChanges()

        XCTAssertEqual(controller.rows.first?.renderedContent, "line 350")
        XCTAssertEqual(controller.rows.count, 849)
        XCTAssertFalse(controller.rows.contains { $0.id == long.blocks[900] })
    }

    func testThePageEndIsReachedWithoutPhantomRowsBelow() throws {
        let graph = try PithGraph.openInMemory()
        let long = try longPage(graph, lines: 700)
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(long.page)
        XCTAssertEqual(controller.rows.count, 500)
        XCTAssertEqual(controller.rowsBelow, 200)

        controller.loadMoreRows()
        XCTAssertEqual(controller.rows.count, 700)
        XCTAssertFalse(controller.hasMoreRows)
        XCTAssertEqual(controller.rowsBelow, 0)
    }
}
