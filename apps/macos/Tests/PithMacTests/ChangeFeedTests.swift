import Combine
import PithCore
import PithMacCore
import XCTest

final class RefreshPlanTests: XCTestCase {
    private func changes(
        reloadAll: Bool = false,
        pages: [String] = [],
        restructured: [String] = [],
        stale: [String] = []
    ) -> FfiGraphChanges {
        FfiGraphChanges(
            cursor: FfiChangeCursor(txnSeq: 9, viewSeq: 4),
            reloadAll: reloadAll,
            pages: pages,
            restructuredPages: restructured,
            staleBlocks: stale
        )
    }

    func testNothingChangedPlansNothing() {
        let plan = RefreshPlan.make(changes(), visiblePages: ["p"], loadedRows: ["a"])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.changesVisibleRows)
    }

    func testAStructuralChangeOnAVisiblePageReloadsItInsteadOfPatching() {
        let plan = RefreshPlan.make(changes(restructured: ["p"], stale: ["a"]), visiblePages: ["p"], loadedRows: ["a"])
        XCTAssertEqual(plan, RefreshPlan(reloadVisible: true, patchRows: [], touchesOtherPages: false))
    }

    func testEditsPatchOnlyLoadedRowsAndFlagEditsElsewhere() {
        let plan = RefreshPlan.make(changes(stale: ["x", "a", "b"]), visiblePages: ["p"], loadedRows: ["a", "b", "c"])
        XCTAssertEqual(plan, RefreshPlan(patchRows: ["a", "b"], touchesOtherPages: true))

        let local = RefreshPlan.make(changes(stale: ["a"]), visiblePages: ["p"], loadedRows: ["a"])
        XCTAssertEqual(local, RefreshPlan(patchRows: ["a"], touchesOtherPages: false))
    }

    func testChangesOnHiddenPagesLeaveRowsAlone() {
        let plan = RefreshPlan.make(changes(restructured: ["q"]), visiblePages: ["p"], loadedRows: ["a"])
        XCTAssertEqual(plan, RefreshPlan(touchesOtherPages: true))
        XCTAssertFalse(plan.changesVisibleRows)
    }

    func testPageRowChangesReloadTheListsOnly() {
        let plan = RefreshPlan.make(changes(pages: ["q"]), visiblePages: ["p"], loadedRows: ["a"])
        XCTAssertEqual(plan, RefreshPlan(reloadPageLists: true, touchesOtherPages: true))
    }

    func testABurstTooLargeToDiffReloadsEverything() {
        let plan = RefreshPlan.make(changes(reloadAll: true), visiblePages: [], loadedRows: [])
        XCTAssertEqual(plan, RefreshPlan(reloadAll: true, reloadPageLists: true, reloadVisible: true, touchesOtherPages: true))
    }
}

@MainActor
final class ChangeFeedTests: XCTestCase {
    private var path = ""
    private var app: PithGraph!
    private var agent: PithGraph!
    private var bag: Set<AnyCancellable> = []
    private let agentMeta = FfiTxMeta(writer: .agent, actor: "agent:cli", session: nil, summary: "cli", undoGroup: nil)

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "pith-feed-\(UUID().uuidString).db"
        app = try PithGraph.open(path: path)
        agent = try PithGraph.open(path: path)
    }

    override func tearDown() async throws {
        bag.removeAll()
        app = nil
        agent = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func page(_ title: String, _ lines: [String]) throws -> (page: String, blocks: [String]) {
        let pageId = newId()
        var ops: [FfiOp] = [.createPage(id: pageId, title: title, journalDay: nil, documentMode: false)]
        var ids: [String] = []
        var key: String?
        for line in lines {
            let next = try orderKeyBetween(lower: key, upper: nil)
            let id = newId()
            ops.append(.insertBlock(id: id, pageId: pageId, parentId: nil, orderKey: next, content: line))
            ids.append(id)
            key = next
        }
        _ = try agent.applyOps(ops: ops, meta: agentMeta)
        return (pageId, ids)
    }

    private func controllerOn(_ pageId: String) throws -> OutlinerController {
        let controller = try OutlinerController(graph: app)
        controller.selectPage(pageId)
        return controller
    }

    private func count<Value>(_ publisher: Published<Value>.Publisher) -> () -> Int {
        var emitted = 0
        publisher.dropFirst().sink { _ in emitted += 1 }.store(in: &bag)
        return { emitted }
    }

    func testAnExternalEditPatchesTheRowInPlace() throws {
        let notes = try page("Notes", ["one", "two", "three"])
        let controller = try controllerOn(notes.page)
        let rowsPublished = count(controller.$rows)

        _ = try agent.applyOps(ops: [.updateBlock(id: notes.blocks[1], content: "two, edited", expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.rows.map(\.renderedContent), ["one", "two, edited", "three"])
        XCTAssertEqual(rowsPublished(), 1)
    }

    func testNothingIsRepublishedWhenNothingChanged() throws {
        let notes = try page("Notes", ["one"])
        let controller = try controllerOn(notes.page)
        var published = 0
        controller.objectWillChange.sink { published += 1 }.store(in: &bag)

        controller.pollExternalChanges()
        controller.applyChanges()

        XCTAssertEqual(published, 0)
    }

    func testRenamingALinkedPageElsewhereUpdatesTheLinkingRow() throws {
        let target = try page("Target", ["body"])
        let notes = try page("Notes", ["see [[Target]] now", "plain"])
        let controller = try controllerOn(notes.page)

        _ = try agent.applyOps(ops: [.renamePage(id: target.page, title: "Renamed", expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.rows.map(\.renderedContent), ["see [[Renamed]] now", "plain"])
        XCTAssertTrue(controller.library.contains { $0.title == "Renamed" })
    }

    func testAnExternalCollapseHidesTheChildren() throws {
        let notes = try page("Notes", ["parent"])
        let child = newId()
        _ = try agent.applyOps(ops: [
            .insertBlock(id: child, pageId: notes.page, parentId: notes.blocks[0], orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "child"),
        ], meta: agentMeta)
        let controller = try controllerOn(notes.page)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["parent", "child"])

        _ = try agent.applyOps(ops: [.setCollapsed(id: notes.blocks[0], collapsed: true)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.rows.map(\.renderedContent), ["parent"])
    }

    func testAnExternalFavoriteUpdatesTheSidebarWithoutTouchingRows() throws {
        let notes = try page("Notes", ["one"])
        let other = try page("Other", ["x"])
        let controller = try controllerOn(notes.page)
        let rowsPublished = count(controller.$rows)

        _ = try agent.applyOps(ops: [.setPageFavorite(id: other.page, favorite: true)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.favoritePages.map(\.title), ["Other"])
        XCTAssertEqual(rowsPublished(), 0)
    }

    func testTodaysJournalCreatedElsewhereAppearsInTheStream() throws {
        let controller = try OutlinerController(graph: app)
        XCTAssertNil(controller.selectedPageId)

        _ = try agent.startJournal(date: nil, meta: agentMeta)
        let today = try XCTUnwrap(agent.journalPage(date: nil))
        let first = try XCTUnwrap(agent.readPageWindow(pageId: today.id, offset: 0, limit: 5).rows.first)
        _ = try agent.applyOps(ops: [.updateBlock(id: first.id, content: "from the phone", expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.selectedPageId, today.id)
        XCTAssertNil(controller.pendingJournalTitle)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["from the phone"])
    }

    func testDeletingTheOpenPageElsewhereGoesBack() throws {
        let home = try page("Home", ["h"])
        let doomed = try page("Doomed", ["d"])
        let controller = try controllerOn(home.page)
        controller.selectPage(doomed.page)

        _ = try agent.applyOps(ops: [.deletePage(id: doomed.page, expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.selectedPageId, home.page)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["h"])
        XCTAssertFalse(controller.canGoForward)
    }

    func testHistoryForgetsAPageDeletedElsewhere() throws {
        let home = try page("Home", ["h"])
        let doomed = try page("Doomed", ["d"])
        let other = try page("Other", ["o"])
        let controller = try controllerOn(home.page)
        controller.selectPage(doomed.page)
        controller.selectPage(other.page)

        _ = try agent.applyOps(ops: [.deletePage(id: doomed.page, expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()
        XCTAssertEqual(controller.selectedPageId, other.page)

        controller.goBack()
        XCTAssertEqual(controller.selectedPageId, home.page)
    }

    func testAPastJournalDayAddedElsewhereJoinsTheStream() throws {
        _ = try agent.startJournal(date: nil, meta: agentMeta)
        let controller = try OutlinerController(graph: app)
        let todayRows = controller.rows.count

        let yesterday = try shiftJournalDay(date: controller.todayTitle, deltaDays: -1)
        _ = try agent.startJournal(date: yesterday, meta: agentMeta)
        let page = try XCTUnwrap(agent.journalPage(date: yesterday))
        let first = try XCTUnwrap(agent.readPageWindow(pageId: page.id, offset: 0, limit: 5).rows.first)
        _ = try agent.applyOps(ops: [.updateBlock(id: first.id, content: "yesterday's note", expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertEqual(controller.journalSections.map(\.title), [controller.todayTitle, yesterday])
        XCTAssertEqual(controller.rows.dropFirst(todayRows).map(\.renderedContent), ["yesterday's note"])
    }

    func testDeletingTheZoomedBlockElsewhereShowsThePage() throws {
        let notes = try page("Notes", ["parent", "sibling"])
        let child = newId()
        _ = try agent.applyOps(ops: [
            .insertBlock(id: child, pageId: notes.page, parentId: notes.blocks[0], orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "child"),
        ], meta: agentMeta)
        let controller = try controllerOn(notes.page)
        controller.zoom(into: notes.blocks[0])
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["parent", "child"])

        _ = try agent.applyOps(ops: [.deleteBlock(id: notes.blocks[0], expectedVersion: nil)], meta: agentMeta)
        controller.pollExternalChanges()

        XCTAssertNil(controller.zoomedBlockId)
        XCTAssertEqual(controller.rows.map(\.renderedContent), ["sibling"])
    }

    func testSavingATypedEditPatchesOneRow() throws {
        let notes = try page("Notes", ["one", "two"])
        let controller = try controllerOn(notes.page)
        controller.debounceNanoseconds = 0
        controller.focusBlock(notes.blocks[0])
        let rowsPublished = count(controller.$rows)

        controller.updateDraft(blockId: notes.blocks[0], text: "one more", isComposing: false)
        controller.flushDraft()

        XCTAssertEqual(controller.rows.map(\.renderedContent), ["one more", "two"])
        XCTAssertEqual(rowsPublished(), 1)
    }
}
