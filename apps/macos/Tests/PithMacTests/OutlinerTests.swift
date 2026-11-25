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

        controller.moveFocusUp()
        XCTAssertEqual(controller.focusedBlockId, firstId)
        controller.moveFocusDown()
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

    func testAnExternalEditWhileTypingIsAConflictNotAnOverwrite() throws {
        let path = NSTemporaryDirectory() + "pith-conflict-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let appGraph = try PithGraph.open(path: path)
        let agentGraph = try PithGraph.open(path: path)
        let controller = try makeController(appGraph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "original")
        let blockId = try XCTUnwrap(controller.focusedBlockId)
        let pageId = try XCTUnwrap(controller.selectedPageId)
        let savedVersion = controller.rows[0].version

        controller.updateDraft(blockId: blockId, text: "my draft", isComposing: false)
        _ = try agentGraph.applyOps(
            ops: [.updateBlock(id: blockId, content: "agent text", expectedVersion: savedVersion)],
            meta: agentMeta()
        )
        controller.pollExternalChanges()
        controller.flushDraft()

        XCTAssertEqual(controller.conflict, EditConflict(blockId: blockId, mine: "my draft", theirs: "agent text"))
        XCTAssertEqual(try agentGraph.readPageWindow(pageId: pageId, offset: 0, limit: 5).rows[0].rawContent, "agent text")

        controller.keepMine()
        XCTAssertNil(controller.conflict)
        XCTAssertEqual(try agentGraph.readPageWindow(pageId: pageId, offset: 0, limit: 5).rows[0].rawContent, "my draft")
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

        XCTAssertNil(controller.conflict)
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

    func testInlineFormatterStylesCoreSpansWithoutReparsing() {
        let spans: [FfiSpan] = [
            .task(state: "TODO"),
            .text(text: " Ship "),
            .pageLink(pageId: "p1", title: "Roadmap"),
            .text(text: " "),
            .tag(pageId: "p2", title: "macos"),
            .text(text: " "),
            .code(text: "`[[x]]`"),
        ]
        let formatted = InlineFormatter.format(spans)
        XCTAssertEqual(String(formatted.characters), "TODO Ship Roadmap #macos `[[x]]`")
        XCTAssertEqual(InlineFormatter.pageId(from: URL(string: "pith://page/p1")!), "p1")
    }

    func testSplittingAfterAnEmojiKeepsTheEmojiIntact() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "👍🏽 ab")

        controller.handleReturn(at: 3)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["👍🏽 ", "ab"])
    }

    func testNavigationIsBlockedWhileAConflictIsUnresolved() throws {
        let path = NSTemporaryDirectory() + "pith-conflict-nav-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let appGraph = try PithGraph.open(path: path)
        let agentGraph = try PithGraph.open(path: path)
        let controller = try makeController(appGraph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "original")
        let blockId = try XCTUnwrap(controller.focusedBlockId)
        let journalId = try XCTUnwrap(controller.selectedPageId)
        controller.openPageByTitle("Elsewhere")
        controller.selectPage(journalId)
        controller.focusBlock(blockId)

        controller.updateDraft(blockId: blockId, text: "my draft", isComposing: false)
        _ = try agentGraph.applyOps(
            ops: [.updateBlock(id: blockId, content: "agent text", expectedVersion: controller.rows[0].version)],
            meta: agentMeta()
        )
        controller.pollExternalChanges()
        XCTAssertNotNil(controller.conflict)

        controller.openPageByTitle("Elsewhere")
        controller.undo()

        XCTAssertEqual(controller.selectedPageId, journalId)
        XCTAssertEqual(controller.draftText, "my draft")
        XCTAssertEqual(controller.conflict?.mine, "my draft")
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
}
