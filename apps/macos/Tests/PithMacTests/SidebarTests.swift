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

        controller.showFavorites()
        XCTAssertEqual(controller.sidebarDestination, .favorites)
        XCTAssertEqual(controller.listScreen, .favorites)

        controller.showAllPages()
        XCTAssertEqual(controller.sidebarDestination, .allPages)

        controller.goBack()
        XCTAssertEqual(controller.sidebarDestination, .favorites)
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
        XCTAssertEqual(controller.sidebarFavorites.map(\.title), ["Starred"])
    }

    func testTheSidebarPinsSevenFavoritesAndTheFavoritesPageListsAll() throws {
        let graph = try PithGraph.openInMemory()
        for letter in ["H", "G", "F", "E", "D", "C", "B", "A", "I"] {
            _ = try page(graph, letter, favorite: true)
        }
        let controller = try OutlinerController(graph: graph)

        XCTAssertEqual(controller.sidebarFavorites.map(\.title), ["A", "B", "C", "D", "E", "F", "G"])
        XCTAssertEqual(controller.favoritePages.count, 9)
    }

    func testUnstarringRemovesAPageFromFavorites() throws {
        let graph = try PithGraph.openInMemory()
        let starred = try page(graph, "Starred", favorite: true)
        let controller = try OutlinerController(graph: graph)
        controller.showFavorites()

        controller.toggleFavorite(starred)
        XCTAssertEqual(controller.favoritePages.map(\.title), [])
        XCTAssertEqual(controller.recentPages.map(\.title), ["Starred"])
        XCTAssertEqual(controller.listScreen, .favorites)
    }
}
