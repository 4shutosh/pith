import Combine
import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class OutlinerTests: XCTestCase {
    private func makeController(_ graph: PithGraph) throws -> OutlinerController {
        let controller = try OutlinerController(graph: graph)
        controller.debounceNanoseconds = 60_000_000_000
        return controller
    }

    private func type(_ controller: OutlinerController, _ text: String) throws {
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: id, text: text, isComposing: false)
        controller.flushDraft()
    }

    private func agentMeta() -> FfiTxMeta {
        FfiTxMeta(writer: .agent, actor: "agent:claude", session: nil, summary: "agent edit", undoGroup: nil)
    }

    func testLaunchingTheAppWritesNothing() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(controller.pageTitle, formatter.string(from: Date()))
        XCTAssertEqual(try graph.listPages().count, 0)
        XCTAssertEqual(try graph.changesSince(afterSeq: 0, limit: 10).entries.count, 0)

        controller.undo()
        XCTAssertEqual(try graph.listPages().count, 0)
    }

    func testFirstBulletCreatesTheJournalAndUndoRemovesIt() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)

        controller.ensureFirstBlockAndFocus()
        XCTAssertEqual(try graph.listPages().count, 1)
        XCTAssertEqual(controller.rows.count, 1)

        controller.blurFocus()
        controller.undo()
        XCTAssertEqual(try graph.listPages().count, 0)
    }

    func testOutlinerCommandsProduceTheExpectedTree() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        let firstId = try XCTUnwrap(controller.focusedBlockId)
        try type(controller, "Hello world")

        controller.handleReturn(at: 5)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Hello", " world"])
        XCTAssertEqual(controller.focusedBlockId, controller.rows[1].id)

        controller.indentFocusedBlock()
        XCTAssertEqual(controller.rows.map(\.depth), [0, 1])
        XCTAssertEqual(controller.rows[1].parentId, firstId)

        controller.outdentFocusedBlock()
        XCTAssertEqual(controller.rows.map(\.depth), [0, 0])

        controller.moveFocusUp(column: 0)
        XCTAssertEqual(controller.focusedBlockId, firstId)
        controller.moveFocusDown(column: 0)
        XCTAssertEqual(controller.focusedBlockId, controller.rows[1].id)

        controller.handleBackspaceAtStart()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Hello world"])
        XCTAssertEqual(controller.focusedBlockId, firstId)
        XCTAssertEqual(controller.requestedCursorOffset, 5)

        controller.undo()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Hello", " world"])
        controller.redo()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Hello world"])
    }

    func testATypingBurstIsOneUndoStep() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "H")
        try type(controller, "Hello")
        try type(controller, "Hello world")

        controller.undo()
        XCTAssertEqual(controller.rows.map(\.renderedContent), [""])
        controller.redo()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Hello world"])
    }

    func testIndentUnderACollapsedBulletKeepsItsChildrenFirst() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "A")
        controller.handleReturn(at: 1)
        try type(controller, "A1")
        controller.indentFocusedBlock()
        controller.handleReturn(at: 2)
        try type(controller, "A2")
        controller.handleReturn(at: 2)
        try type(controller, "B")
        controller.outdentFocusedBlock()
        let aId = controller.rows[0].id
        controller.toggleCollapse(aId)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["A", "B"])

        controller.focusBlock(controller.rows[1].id)
        controller.indentFocusedBlock()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["A", "A1", "A2", "B"])
        XCTAssertEqual(controller.rows.map(\.depth), [0, 1, 1, 1])
    }

    func testAnExternalEditWithoutLocalTypingIsAdoptedSilently() throws {
        let path = NSTemporaryDirectory() + "pith-adopt-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let appGraph = try PithGraph.open(path: path)
        let agentGraph = try PithGraph.open(path: path)
        let controller = try makeController(appGraph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "original")
        let blockId = try XCTUnwrap(controller.focusedBlockId)

        _ = try agentGraph.applyOps(
            ops: [.updateBlock(id: blockId, content: "agent text", expectedVersion: controller.rows[0].version)],
            meta: agentMeta()
        )
        controller.pollExternalChanges()

        XCTAssertEqual(controller.draftText, "agent text")
    }

    func testImeCompositionIsNotSavedUntilCommitted() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        let id = try XCTUnwrap(controller.focusedBlockId)

        controller.updateDraft(blockId: id, text: "nihon", isComposing: true)
        controller.flushDraft()
        XCTAssertEqual(controller.rows[0].renderedContent, "")

        controller.updateDraft(blockId: id, text: "日本", isComposing: false)
        controller.flushDraft()
        XCTAssertEqual(controller.rows[0].renderedContent, "日本")
    }



    func testSplittingAfterAnEmojiKeepsTheEmojiIntact() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "👍🏽 ab")

        controller.handleReturn(at: 3)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["👍🏽 ", "ab"])
    }

    func testTypingAfterAnIndentIsASeparateUndoStep() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "Parent")
        controller.handleReturn(at: 6)
        try type(controller, "x")
        controller.indentFocusedBlock()
        try type(controller, "xy")

        controller.undo()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["Parent", "x"])
        XCTAssertEqual(controller.rows.map(\.depth), [0, 1])
    }

    private func seedBlock(_ graph: PithGraph, _ controller: OutlinerController, _ content: String) throws -> String {
        controller.ensureFirstBlockAndFocus()
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.blurFocus()
        _ = try graph.applyOps(
            ops: [.updateBlock(id: id, content: content, expectedVersion: nil)],
            meta: FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)
        )
        controller.reload()
        return id
    }

    func testEditingATaskEditsOnlyTheTextAndKeepsTheKeyword() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        let id = try seedBlock(graph, controller, "TODO write the ADR")

        controller.focusBlock(id)
        XCTAssertEqual(controller.draftText, "write the ADR")
        try type(controller, "write the ADR today")
        XCTAssertEqual(controller.rows[0].rawContent, "TODO write the ADR today")
    }

    func testCommandReturnCyclesTheTaskWithoutTouchingTheText() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        let id = try seedBlock(graph, controller, "write the ADR")
        controller.focusBlock(id)

        controller.cycleTask(caret: 5)
        XCTAssertEqual(controller.rows[0].rawContent, "TODO write the ADR")
        XCTAssertEqual(controller.draftText, "write the ADR")
        XCTAssertEqual(controller.requestedCursorOffset, 5)

        controller.cycleTask(caret: 5)
        XCTAssertEqual(controller.rows[0].rawContent, "DOING write the ADR")
    }

    func testClickingTheStatusCircleTicksATaskWithoutStartingToEdit() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        let id = try seedBlock(graph, controller, "DOING ship it")

        controller.toggleTaskDone(id)
        XCTAssertEqual(controller.rows[0].rawContent, "DONE ship it")
        XCTAssertNil(controller.focusedBlockId)
    }

    func testArrowKeysKeepTheColumnAcrossBlocks() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "first line\nlast line here")
        controller.handleReturn(at: 24)
        try type(controller, "next block")

        controller.moveFocusUp(column: 4)
        XCTAssertEqual(controller.requestedCursorOffset, 15)

        controller.moveFocusDown(column: 30)
        XCTAssertEqual(controller.requestedCursorOffset, 10)
    }

    func testSavingWhileTypingRefreshesOnlyTheEditedRow() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "one")
        controller.handleReturn(at: 3)
        try type(controller, "two")
        var pagePublishes = 0
        var backlinkPublishes = 0
        let pagesWatch = controller.$pages.dropFirst().sink { _ in pagePublishes += 1 }
        let backlinksWatch = controller.$backlinks.dropFirst().sink { _ in backlinkPublishes += 1 }

        try type(controller, "two more")

        XCTAssertEqual(controller.rows.map(\.renderedContent), ["one", "two more"])
        XCTAssertEqual(pagePublishes, 0)
        XCTAssertEqual(backlinkPublishes, 0)
        pagesWatch.cancel()
        backlinksWatch.cancel()

        try type(controller, "two more [[New Page]]")
        XCTAssertTrue(controller.pages.contains { $0.title == "New Page" })
    }

    func testTypingDoesNotRepublishTheController() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        let id = try XCTUnwrap(controller.focusedBlockId)

        var changes = 0
        let watch = controller.objectWillChange.sink { changes += 1 }
        controller.updateDraft(blockId: id, text: "H", isComposing: false)
        controller.updateDraft(blockId: id, text: "He", isComposing: false)
        controller.updateDraft(blockId: id, text: "Hel", isComposing: false)
        watch.cancel()

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(controller.draftText, "Hel")
    }

    func testTypingIntoAnEmptyTaskKeepsTheSpaceAfterTheKeyword() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()

        controller.cycleTask(caret: 0)
        try type(controller, "Make things work")
        controller.handleReturn(at: TextOffsets.length("Make things work"))

        XCTAssertEqual(controller.rows[0].renderedContent, "TODO Make things work")
        XCTAssertEqual(BlockPresentation.runs(controller.rows[0].spans).status, .todo)
    }

    func testTypingIntoAnEmptyTaskAndHittingReturnBeforeFlushKeepsTheSpace() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()

        controller.cycleTask(caret: 0)
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: id, text: "Make things work", isComposing: false)
        controller.handleReturn(at: TextOffsets.length("Make things work"))

        XCTAssertEqual(controller.rows[0].renderedContent, "TODO Make things work")
        XCTAssertEqual(BlockPresentation.runs(controller.rows[0].spans).status, .todo)
    }

    func testTypingTodoManuallyDoesNotDoubleThePrefixOnSubsequentSaves() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()

        try type(controller, "TODO Make")
        try type(controller, "TODO Make things work")

        XCTAssertEqual(controller.rows[0].renderedContent, "TODO Make things work")
        XCTAssertEqual(BlockPresentation.runs(controller.rows[0].spans).status, .todo)
    }
}
