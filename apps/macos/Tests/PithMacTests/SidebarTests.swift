import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class SidebarTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    private func page(_ graph: PithGraph, _ title: String, favorite: Bool = false) throws -> String {
        let id = newId()
        var ops: [FfiOp] = [.createPage(id: id, title: title, journalDay: nil, documentMode: false)]
        if favorite {
            ops.append(.setPageFavorite(id: id, favorite: true))
        }
        _ = try graph.applyOps(ops: ops, meta: setup)
        return id
    }

    func testOnlyOneSidebarItemIsSelectedForEachView() throws {
        let graph = try PithGraph.openInMemory()
        let starred = try page(graph, "Starred", favorite: true)
        let plain = try page(graph, "Plain")
        _ = try graph.startJournal(date: "2020-01-02", meta: setup)
        let controller = try OutlinerController(graph: graph)

        XCTAssertEqual(controller.sidebarDestination, .journals)

        controller.selectPage(starred)
        XCTAssertEqual(controller.sidebarDestination, .page(starred))
        XCTAssertFalse(controller.recentPages.contains { $0.id == starred })

        controller.selectPage(plain)
        XCTAssertEqual(controller.sidebarDestination, .page(plain))

        controller.openJournal(date: "2020-01-02")
        XCTAssertEqual(controller.sidebarDestination, .journals)

        controller.showAllPages()
        XCTAssertEqual(controller.sidebarDestination, .allPages)

        controller.goBack()
        XCTAssertEqual(controller.sidebarDestination, .journals)
        XCTAssertNil(controller.listScreen)
    }

    func testRecentLeavesOutJournalsAndFavorites() throws {
        let graph = try PithGraph.openInMemory()
        _ = try page(graph, "Starred", favorite: true)
        _ = try page(graph, "Plain")
        _ = try graph.startJournal(date: "2020-01-02", meta: setup)
        let controller = try OutlinerController(graph: graph)

        XCTAssertEqual(controller.recentPages.map(\.title), ["Plain"])
        XCTAssertEqual(controller.favoritePages.map(\.title), ["Starred"])
    }

    func testEveryFavoriteIsPinnedInTheSidebarAlphabetically() throws {
        let graph = try PithGraph.openInMemory()
        for letter in ["H", "G", "F", "E", "D", "C", "B", "A", "I"] {
            _ = try page(graph, letter, favorite: true)
        }
        let controller = try OutlinerController(graph: graph)

        XCTAssertEqual(controller.favoritePages.map(\.title), ["A", "B", "C", "D", "E", "F", "G", "H", "I"])
        controller.selectPage(try XCTUnwrap(controller.favoritePages.last).id)
        XCTAssertEqual(controller.sidebarDestination, .page(try XCTUnwrap(controller.favoritePages.last).id))
    }

    func testUnstarringMovesAPageFromFavoritesToRecent() throws {
        let graph = try PithGraph.openInMemory()
        let starred = try page(graph, "Starred", favorite: true)
        let controller = try OutlinerController(graph: graph)

        controller.toggleFavorite(starred)
        XCTAssertEqual(controller.favoritePages.map(\.title), [])
        XCTAssertEqual(controller.recentPages.map(\.title), ["Starred"])
    }

    func testDeletingAnInactivePageFromSidebarKeepsCurrentPageOpen() throws {
        let graph = try PithGraph.openInMemory()
        let first = try page(graph, "First")
        let second = try page(graph, "Second")
        let controller = try OutlinerController(graph: graph)

        controller.selectPage(first)
        controller.deletePage(second)

        XCTAssertEqual(controller.selectedPageId, first)
        XCTAssertFalse(controller.library.contains { $0.id == second })
    }

    func testPageDirectoryFiltersAndSortsSummaries() {
        func summary(
            _ title: String,
            journal: Int32? = nil,
            favorite: Bool = false,
            updated: Int64,
            blocks: UInt64,
            backlinks: UInt64
        ) -> FfiPageSummary {
            FfiPageSummary(
                page: FfiPage(
                    id: title,
                    title: title,
                    journalDay: journal,
                    documentMode: false,
                    favorite: favorite,
                    version: 1,
                    updatedAt: updated
                ),
                blockCount: blocks,
                backlinkCount: backlinks
            )
        }

        let items = [
            summary("Beta", updated: 10, blocks: 5, backlinks: 1),
            summary("Alpha", favorite: true, updated: 30, blocks: 2, backlinks: 9),
            summary("Stub", updated: 20, blocks: 0, backlinks: 3),
            summary("2026-11-26", journal: 20261126, updated: 40, blocks: 4, backlinks: 0),
        ]

        XCTAssertEqual(PageDirectory.count(in: items, for: .pages), 3)
        XCTAssertEqual(PageDirectory.count(in: items, for: .favorites), 1)
        XCTAssertEqual(PageDirectory.count(in: items, for: .journals), 1)
        XCTAssertEqual(PageDirectory.count(in: items, for: .empty), 1)

        XCTAssertEqual(
            PageDirectory.filter(items, tab: .pages, query: "", sort: .backlinks).map(\.page.title),
            ["Alpha", "Stub", "Beta"]
        )
        XCTAssertEqual(
            PageDirectory.filter(items, tab: .pages, query: "", sort: .blocks).map(\.page.title),
            ["Beta", "Alpha", "Stub"]
        )
        XCTAssertEqual(
            PageDirectory.filter(items, tab: .pages, query: "al", sort: .title).map(\.page.title),
            ["Alpha"]
        )
        XCTAssertTrue(PageDirectory.offersCreate(query: "Gamma", in: items))
        XCTAssertFalse(PageDirectory.offersCreate(query: "alpha", in: items))
    }
}

final class PageDirectoryLayoutTests: XCTestCase {
    func testTheDirectoryDropsDetailAsTheColumnNarrows() {
        XCTAssertEqual(PageDirectoryLayout(width: 820), PageDirectoryLayout(stacksHeader: false, compactSort: false, showsCounts: true, updatedInColumn: true))
        XCTAssertEqual(PageDirectoryLayout(width: 540), PageDirectoryLayout(stacksHeader: false, compactSort: true, showsCounts: true, updatedInColumn: true))
        XCTAssertEqual(PageDirectoryLayout(width: 500), PageDirectoryLayout(stacksHeader: true, compactSort: true, showsCounts: true, updatedInColumn: true))
        XCTAssertEqual(PageDirectoryLayout(width: 390), PageDirectoryLayout(stacksHeader: true, compactSort: true, showsCounts: false, updatedInColumn: true))
        XCTAssertEqual(PageDirectoryLayout(width: 290), PageDirectoryLayout(stacksHeader: true, compactSort: true, showsCounts: false, updatedInColumn: false))
    }
}

final class PageDirectoryMergeTests: XCTestCase {
    private func page(_ id: String, _ title: String, favorite: Bool = false) -> FfiPage {
        FfiPage(id: id, title: title, journalDay: nil, documentMode: false, favorite: favorite, version: 1, updatedAt: 0)
    }

    func testTheListFollowsTheLibraryWhileCountsCatchUp() {
        let library = PageLibrary([page("a", "Alpha renamed", favorite: true), page("b", "Brand new")])
        let staleCounts = [
            FfiPageSummary(page: page("a", "Alpha"), blockCount: 3, backlinkCount: 2),
            FfiPageSummary(page: page("c", "Deleted since"), blockCount: 9, backlinkCount: 9),
        ]

        let merged = PageDirectory.merge(library, counts: staleCounts).sorted { $0.page.id < $1.page.id }

        XCTAssertEqual(merged.map(\.page.title), ["Alpha renamed", "Brand new"])
        XCTAssertEqual(merged.map(\.page.favorite), [true, false])
        XCTAssertEqual(merged.map(\.blockCount), [3, 0])
        XCTAssertEqual(merged.map(\.backlinkCount), [2, 0])
    }
}
