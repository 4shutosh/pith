import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class EditorFlowTests: XCTestCase {
    private func makeController(_ graph: PithGraph) throws -> OutlinerController {
        let controller = try OutlinerController(graph: graph)
        controller.debounceNanoseconds = 60_000_000_000
        return controller
    }

    private func type(_ controller: OutlinerController, _ text: String, caret: Int? = nil) throws {
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: id, text: text, isComposing: false, caret: caret)
        controller.flushDraft()
    }

    private func outline(_ controller: OutlinerController) -> [String] {
        controller.rows.map { String(repeating: "  ", count: Int($0.depth)) + $0.renderedContent }
    }

    func testZoomShowsOnlyTheSubtreeWithABreadcrumb() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "Parent")
        controller.handleReturn(at: 6)
        try type(controller, "Child")
        controller.indentFocusedBlock()
        controller.handleReturn(at: 5)
        controller.outdentFocusedBlock()
        try type(controller, "Sibling")
        let parentId = controller.rows[0].id

        controller.zoom(into: parentId)
        XCTAssertEqual(outline(controller), ["Parent", "  Child"])
        XCTAssertEqual(controller.breadcrumb.map(\.label), [controller.todayTitle, "Parent"])
        XCTAssertEqual(controller.pageTitle, controller.todayTitle)
        XCTAssertTrue(controller.isShowingToday)

        let childId = controller.rows[1].id
        controller.zoom(into: childId)
        XCTAssertEqual(controller.breadcrumb.map(\.label), [controller.todayTitle, "Parent", "Child"])
        controller.zoomOutOneLevel()
        XCTAssertEqual(controller.zoomedBlockId, parentId)

        controller.zoomOut(to: controller.breadcrumb[0])
        XCTAssertNil(controller.zoomedBlockId)
        controller.zoomOutOneLevel()
        XCTAssertNil(controller.zoomedBlockId)
        XCTAssertEqual(outline(controller), ["Parent", "  Child", "Sibling"])
    }

    func testOptionArrowsMoveTheBlockAndKeepEditing() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "A")
        controller.handleReturn(at: 1)
        try type(controller, "Bravo")
        let bravo = try XCTUnwrap(controller.focusedBlockId)

        controller.moveFocusedBlock(up: true, caret: 2)
        XCTAssertEqual(outline(controller), ["Bravo", "A"])
        XCTAssertEqual(controller.focusedBlockId, bravo)
        XCTAssertEqual(controller.requestedCursorOffset, 2)

        controller.moveFocusedBlock(up: true, caret: 2)
        XCTAssertEqual(outline(controller), ["Bravo", "A"])
    }

    func testCommandPeriodCollapsesWhileStayingInTheBlock() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "Parent")
        controller.handleReturn(at: 6)
        try type(controller, "Child")
        controller.indentFocusedBlock()
        controller.moveFocusUp(column: 0)
        let parent = try XCTUnwrap(controller.focusedBlockId)

        controller.toggleFocusedCollapse(caret: 3)
        XCTAssertEqual(outline(controller), ["Parent"])
        XCTAssertEqual(controller.focusedBlockId, parent)

        controller.toggleFocusedCollapse(caret: 3)
        XCTAssertEqual(outline(controller), ["Parent", "  Child"])
    }

    func testPastingAnOutlineSplitsIntoBlocks() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "Hello world")

        XCTAssertTrue(controller.paste("- One\n- Two\n  - Two child", selectionStart: 6, selectionEnd: 6))
        XCTAssertEqual(outline(controller), ["Hello One", "Twoworld", "  Two child"])
        XCTAssertEqual(controller.focusedBlockId, controller.rows[1].id)
        XCTAssertEqual(controller.requestedCursorOffset, 3)

        XCTAssertFalse(controller.paste("one line only", selectionStart: 0, selectionEnd: 0))
    }

    func testCopyAsMarkdownIncludesChildren() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "Parent")
        controller.handleReturn(at: 6)
        try type(controller, "Child")
        controller.indentFocusedBlock()
        controller.moveFocusUp(column: 0)

        XCTAssertEqual(controller.focusedBlockMarkdown(), "- Parent\n  - Child")
    }

    func testTypingDoubleBracketsSuggestsPagesAndAcceptingInsertsTheLink() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.openPageByTitle("Roadmap")
        controller.openTodayJournal()
        controller.ensureFirstBlockAndFocus()

        try type(controller, "see [[Ro]]", caret: 8)
        let state = try XCTUnwrap(controller.completion)
        XCTAssertEqual(state.items.map(\.label), ["Roadmap", "Ro"])
        XCTAssertEqual(state.items.map(\.isNew), [false, true])

        controller.acceptCompletion()
        XCTAssertNil(controller.completion)
        XCTAssertEqual(controller.draftText, "see [[Roadmap]]")
        XCTAssertEqual(controller.requestedCursorOffset, 15)
        XCTAssertEqual(controller.rows[0].renderedContent, "see [[Roadmap]]")
        let roadmap = try XCTUnwrap(graph.getPageByTitle(title: "Roadmap"))
        XCTAssertEqual(try graph.backlinks(targetId: roadmap.id).count, 1)
    }

    func testCompletionSelectionWrapsAndEscapeDismisses() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        try type(controller, "#ne", caret: 3)
        XCTAssertEqual(controller.completion?.items.map(\.label), ["ne"])

        controller.moveCompletion(1)
        XCTAssertEqual(controller.completion?.selected, 0)
        controller.dismissCompletion()
        XCTAssertNil(controller.completion)
    }

    func testOpeningASearchHitBeyondTheLoadedRowsLoadsItsSurroundings() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try makeController(graph)
        controller.ensureFirstBlockAndFocus()
        controller.blurFocus()
        let pageId = try XCTUnwrap(controller.selectedPageId)
        var ops: [FfiOp] = []
        var key = try XCTUnwrap(controller.rows.last?.orderKey)
        for i in 0..<10 {
            key = try orderKeyBetween(lower: key, upper: nil)
            let text = i == 9 ? "needle row" : "row \(i)"
            ops.append(.insertBlock(id: newId(), pageId: pageId, parentId: nil, orderKey: key, content: text))
        }
        _ = try graph.applyOps(
            ops: ops,
            meta: FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)
        )
        controller.pageWindowLimit = 4
        controller.openTodayJournal()
        XCTAssertEqual(controller.rows.count, 4)
        XCTAssertFalse(controller.rows.contains { $0.renderedContent == "needle row" })

        let hit = try XCTUnwrap(controller.searchHitsFor("needle").first)
        controller.openSearchHit(hit)
        XCTAssertEqual(controller.rows.first { $0.id == controller.focusedBlockId }?.renderedContent, "needle row")
    }
}

final class ZoomTrailTests: XCTestCase {
    private func crumbs(_ labels: [String]) -> [FfiCrumb] {
        labels.enumerated().map { index, label in FfiCrumb(blockId: index == 0 ? nil : "b\(index)", label: label) }
    }

    func testTheTrailShowsAncestorsButNotTheZoomedBlock() {
        let trail = crumbs(["Today", "A", "B"])
        XCTAssertEqual(ZoomTrail.items(trail, maxVisible: 4), [.crumb(trail[0]), .crumb(trail[1])])
    }

    func testALongTrailKeepsThePageAndTheNearestAncestors() {
        let trail = crumbs(["Today", "A", "B", "C", "D", "E"])
        XCTAssertEqual(
            ZoomTrail.items(trail, maxVisible: 4),
            [.crumb(trail[0]), .hidden([trail[1]]), .crumb(trail[2]), .crumb(trail[3]), .crumb(trail[4])]
        )
    }

    func testATrailAtTheLimitIsNotShortened() {
        let trail = crumbs(["Today", "A", "B", "C", "D"])
        XCTAssertEqual(ZoomTrail.items(trail, maxVisible: 4), trail.dropLast().map(TrailItem.crumb))
    }
}

private extension OutlinerController {
    func searchHitsFor(_ query: String) -> [FfiSearchHit] {
        runSearch(query)
        return searchHits
    }
}
