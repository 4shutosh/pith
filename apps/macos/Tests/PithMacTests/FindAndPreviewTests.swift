import AppKit
import PithCore
import PithMacCore
import XCTest

@MainActor
final class FindAndPreviewTests: XCTestCase {
    private func background(_ text: NSAttributedString, _ index: Int) -> NSColor? {
        text.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testTheViewHighlightsExactlyTheRangesTheCoreFound() throws {
        var fixture = try RowFixture()
        let id = try fixture.add("**Bold** word pith")
        let matches = try fixture.graph.findInPage(pageId: fixture.pageId, rootBlockId: nil, query: "pith")
        XCTAssertEqual(matches, [FfiPageMatch(blockId: id, start: 10, len: 4)])

        let runs = BlockPresentation.runs(try fixture.row(id).display).runs
        let shown = BlockStyle.display(runs, closed: false, findMatches: matches, activeFindOrdinal: 0)
        XCTAssertEqual(shown.string, "Bold word pith")
        XCTAssertNil(background(shown, 9))
        XCTAssertNotNil(background(shown, 10))
        XCTAssertNotNil(background(shown, 13))
        XCTAssertEqual(shown.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, Theme.nsTextStrong)
    }

    func testFindReachesAMatchInsideACollapsedBlockAndRevealsIt() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        controller.openPageByTitle("Notes")
        let pageId = try XCTUnwrap(controller.selectedPageId)
        let parent = newId()
        let child = newId()
        let first = try orderKeyBetween(lower: nil, upper: nil)
        _ = try graph.applyOps(
            ops: [
                .insertBlock(id: parent, pageId: pageId, parentId: nil, orderKey: first, content: "parent"),
                .insertBlock(id: child, pageId: pageId, parentId: parent, orderKey: first, content: "hidden needle"),
                .setCollapsed(id: parent, collapsed: true),
            ],
            meta: RowFixture.meta
        )
        controller.reload()
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["parent"])

        controller.perform(.findInPage)
        controller.updateFindQuery("needle")
        XCTAssertEqual(controller.findMatches.map(\.blockId), [child])
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["parent", "hidden needle"])
    }

    private func preview(
        title: String = "Page",
        deleted: Bool = false,
        blocks: UInt64 = 0,
        backlinks: UInt64 = 0,
        path: [String] = []
    ) -> FfiLinkPreview {
        FfiLinkPreview(title: title, deleted: deleted, lines: [], totalBlocks: blocks, backlinkCount: backlinks, parentPath: path)
    }

    func testPreviewWordingComesFromTheFacts() {
        XCTAssertEqual(PreviewWording.subtitle(preview()), "Empty page")
        XCTAssertEqual(PreviewWording.subtitle(preview(blocks: 2)), "2 blocks")
        XCTAssertEqual(PreviewWording.subtitle(preview(blocks: 1, backlinks: 1)), "1 block · 1 backlink")
        XCTAssertEqual(PreviewWording.subtitle(preview(blocks: 3, backlinks: 2)), "3 blocks · 2 backlinks")
        XCTAssertEqual(PreviewWording.subtitle(preview(blocks: 1, path: ["Pith", "Roadmap"])), "Pith › Roadmap")
        XCTAssertEqual(PreviewWording.subtitle(preview(title: "Gone", deleted: true)), "Deleted · click the link to restore")
        XCTAssertEqual(PreviewWording.title(preview(title: "", deleted: true)), "Deleted block")
        XCTAssertNil(PreviewWording.subtitle(preview(title: "", deleted: true)))
    }
}
