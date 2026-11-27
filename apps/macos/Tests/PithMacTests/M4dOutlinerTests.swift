import AppKit
import PithCore
import PithMacCore
import XCTest

@MainActor
final class M4dOutlinerTests: XCTestCase {
    private func meta(_ summary: String = "test") -> FfiTxMeta {
        FfiTxMeta(writer: .user, actor: "me", session: nil, summary: summary, undoGroup: nil)
    }

    func testHeadingAndQuotePrefixesAreHiddenInDisplayAndPreserveClickMapping() throws {
        var fixture = try RowFixture()
        let hRuns = BlockPresentation.runs(try fixture.row(for: "## Architecture").display).runs
        XCTAssertEqual(hRuns.map(\.display).joined(), "Architecture")
        XCTAssertEqual(hRuns.map(\.source).joined(), "## Architecture")
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 4, in: hRuns), 7)

        let qRuns = BlockPresentation.runs(try fixture.row(for: "> Wisdom").display).runs
        XCTAssertEqual(qRuns.map(\.display).joined(), "Wisdom")
        XCTAssertEqual(qRuns.map(\.source).joined(), "> Wisdom")
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 3, in: qRuns), 5)
    }

    func testDeletedLinksCarryDeletedTitleAttributeAndBlockRefsCarryBlockId() throws {
        var fixture = try RowFixture()
        let target = try fixture.add("Target")
        let id = try fixture.add("[[Old]] ((\(target)))")
        let old = try XCTUnwrap(fixture.graph.getPageByTitle(title: "Old"))
        _ = try fixture.graph.applyOps(ops: [.deletePage(id: old.id, expectedVersion: nil)], meta: RowFixture.meta)
        let runs = BlockPresentation.runs(try fixture.row(id).display).runs
        let attributed = BlockStyle.display(runs, closed: false)
        XCTAssertEqual(attributed.attribute(.pithDeletedPageTitle, at: 2, effectiveRange: nil) as? String, "Old")
        XCTAssertEqual(attributed.attribute(.pithPageId, at: 2, effectiveRange: nil) as? String, old.id)
        let refIndex = (attributed.string as NSString).range(of: "Target").location
        XCTAssertEqual(attributed.attribute(.pithBlockRefId, at: refIndex, effectiveRange: nil) as? String, target)
    }

    func testFindInPageCyclesMatchesAndClosesCleanly() throws {
        let graph = try PithGraph.openInMemory()
        let pageId = newId()
        let b1 = newId()
        let b2 = newId()
        let k1 = try orderKeyBetween(lower: nil, upper: nil)
        let k2 = try orderKeyBetween(lower: k1, upper: nil)
        _ = try graph.applyOps(ops: [
            .createPage(id: pageId, title: "Notes", journalDay: nil, documentMode: false),
            .insertBlock(id: b1, pageId: pageId, parentId: nil, orderKey: k1, content: "Alpha alpha"),
            .insertBlock(id: b2, pageId: pageId, parentId: nil, orderKey: k2, content: "Second ALPHA"),
        ], meta: meta())

        let controller = try OutlinerController(graph: graph)
        controller.selectPage(pageId)
        controller.openFind()
        controller.updateFindQuery("alpha")

        XCTAssertEqual(controller.findMatches.count, 3)
        XCTAssertEqual(controller.activeFindIndex, 0)
        XCTAssertEqual(controller.activeFindOrdinal(in: b1), 0)

        controller.nextFindMatch()
        XCTAssertEqual(controller.activeFindIndex, 1)
        XCTAssertEqual(controller.activeFindOrdinal(in: b1), 1)

        controller.nextFindMatch()
        XCTAssertEqual(controller.activeFindIndex, 2)
        XCTAssertEqual(controller.activeFindOrdinal(in: b2), 0)

        controller.previousFindMatch()
        XCTAssertEqual(controller.activeFindIndex, 1)

        controller.closeFind()
        XCTAssertFalse(controller.isFindOpen)
        XCTAssertTrue(controller.findMatches.isEmpty)
    }

    func testExpandAndCollapseAllToggleHierarchy() throws {
        let graph = try PithGraph.openInMemory()
        let pageId = newId()
        let parent = newId()
        let child = newId()
        _ = try graph.applyOps(ops: [
            .createPage(id: pageId, title: "Outline", journalDay: nil, documentMode: false),
            .insertBlock(id: parent, pageId: pageId, parentId: nil, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Parent"),
            .insertBlock(id: child, pageId: pageId, parentId: parent, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Child"),
        ], meta: meta())

        let controller = try OutlinerController(graph: graph)
        controller.selectPage(pageId)
        XCTAssertEqual(controller.rows.count, 2)

        controller.setAllCollapsed(true)
        XCTAssertEqual(controller.rows.count, 1)

        controller.setAllCollapsed(false)
        XCTAssertEqual(controller.rows.count, 2)
    }

    func testOpenBlockRevealsCollapsedTargetAndPushesBackHistory() throws {
        let graph = try PithGraph.openInMemory()
        let home = newId()
        let targetPage = newId()
        let parent = newId()
        let child = newId()
        _ = try graph.applyOps(ops: [
            .createPage(id: home, title: "Home", journalDay: nil, documentMode: false),
            .createPage(id: targetPage, title: "Target", journalDay: nil, documentMode: false),
            .insertBlock(id: parent, pageId: targetPage, parentId: nil, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Parent"),
            .insertBlock(id: child, pageId: targetPage, parentId: parent, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Deep block"),
            .setCollapsed(id: parent, collapsed: true),
        ], meta: meta())

        let controller = try OutlinerController(graph: graph)
        controller.selectPage(home)
        controller.openBlock(id: child)

        XCTAssertEqual(controller.selectedPageId, targetPage)
        XCTAssertEqual(controller.focusedBlockId, child)
        XCTAssertTrue(controller.canGoBack)

        controller.goBack()
        XCTAssertEqual(controller.selectedPageId, home)
    }

    func testUnlinkedReferencesLoadLazilyAndLinkConvertsToBacklink() throws {
        let graph = try PithGraph.openInMemory()
        let rustPage = newId()
        let notesPage = newId()
        let blockId = newId()
        _ = try graph.applyOps(ops: [
            .createPage(id: rustPage, title: "Rust", journalDay: nil, documentMode: false),
            .createPage(id: notesPage, title: "Notes", journalDay: nil, documentMode: false),
            .insertBlock(id: blockId, pageId: notesPage, parentId: nil, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Writing rust today"),
        ], meta: meta())

        let controller = try OutlinerController(graph: graph)
        controller.selectPage(rustPage)
        XCTAssertFalse(controller.unlinkedRefsLoaded)
        XCTAssertTrue(controller.unlinkedRefs.isEmpty)

        controller.loadUnlinkedReferences()
        XCTAssertTrue(controller.unlinkedRefsLoaded)
        XCTAssertEqual(controller.unlinkedRefs.count, 1)
        XCTAssertEqual(controller.backlinks.count, 0)

        controller.linkUnlinkedReference(blockId: blockId)
        XCTAssertEqual(controller.unlinkedRefs.count, 0)
        XCTAssertEqual(controller.backlinks.count, 1)
    }

    func testRestoreDeletedPageReopensAndRestoresPage() throws {
        let graph = try PithGraph.openInMemory()
        let home = newId()
        let legacy = newId()
        _ = try graph.applyOps(ops: [
            .createPage(id: home, title: "Home", journalDay: nil, documentMode: false),
            .createPage(id: legacy, title: "Legacy", journalDay: nil, documentMode: false),
            .deletePage(id: legacy, expectedVersion: 1),
        ], meta: meta())

        let controller = try OutlinerController(graph: graph)
        controller.selectPage(home)
        controller.requestRestorePage(id: legacy, title: "Legacy")
        XCTAssertEqual(controller.pendingPageRestore?.id, legacy)

        controller.confirmPendingRestore()
        XCTAssertNil(controller.pendingPageRestore)
        XCTAssertEqual(controller.selectedPageId, legacy)
        XCTAssertEqual(controller.currentPage?.title, "Legacy")
    }
}
