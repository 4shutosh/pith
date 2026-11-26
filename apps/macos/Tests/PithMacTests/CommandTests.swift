import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class CommandTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    private func page(_ graph: PithGraph, _ title: String) throws -> String {
        let id = newId()
        _ = try graph.applyOps(ops: [.createPage(id: id, title: title, journalDay: nil, documentMode: false)], meta: setup)
        return id
    }

    private func titles(_ controller: OutlinerController) -> [String] {
        controller.paletteItems.map(\.title)
    }

    func testTheJournalsStreamOffersDayCommandsButNoPageEdits() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory())
        XCTAssertEqual(
            titles(controller),
            ["Go to Journals", "Previous Day", "Next Day", "Go to All Pages", "Toggle Sidebar", "Toggle Light/Dark"]
        )
    }

    func testARegularPageOffersFavoriteRenameAndDelete() throws {
        let graph = try PithGraph.openInMemory()
        let id = try page(graph, "Roadmap")
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(id)

        XCTAssertEqual(
            titles(controller),
            ["Add to Favorites", "Rename Page", "Delete Page…", "Go to Journals", "Go to All Pages", "Back", "Toggle Sidebar", "Toggle Light/Dark"]
        )
        XCTAssertEqual(controller.paletteItems.first?.shortcut, "⌘D")

        controller.perform(.toggleFavorite)
        XCTAssertEqual(controller.favoritePages.map(\.title), ["Roadmap"])
        XCTAssertEqual(controller.paletteItems.first?.title, "Remove from Favorites")

        let before = controller.renameRequest
        controller.perform(.renamePage)
        XCTAssertEqual(controller.renameRequest, before + 1)
    }

    func testDeletingAPageWaitsForConfirmation() throws {
        let graph = try PithGraph.openInMemory()
        let id = try page(graph, "Scratch")
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(id)

        controller.perform(.deletePage)
        XCTAssertEqual(controller.pendingPageDelete?.title, "Scratch")
        XCTAssertTrue(controller.pages.contains { $0.id == id })

        controller.confirmPendingDelete()
        XCTAssertNil(controller.pendingPageDelete)
        XCTAssertFalse(controller.pages.contains { $0.id == id })
    }

    func testJournalPagesCanBeFavoritedButNotRenamedOrDeleted() throws {
        let graph = try PithGraph.openInMemory()
        _ = try graph.startJournal(date: "2020-01-02", meta: setup)
        let controller = try OutlinerController(graph: graph)
        controller.openJournal(date: "2020-01-02")

        XCTAssertTrue(controller.isAvailable(.toggleFavorite))
        XCTAssertFalse(controller.isAvailable(.renamePage))
        XCTAssertFalse(controller.isAvailable(.deletePage))
        let journalId = try XCTUnwrap(controller.selectedPageId)
        controller.requestDelete(journalId)
        XCTAssertNil(controller.pendingPageDelete)
    }

    func testThePaletteFiltersByTitleAndKeywords() throws {
        let graph = try PithGraph.openInMemory()
        let id = try page(graph, "Roadmap")
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(id)

        XCTAssertEqual(controller.paletteItems(matching: "fav").map(\.title), ["Add to Favorites"])
        XCTAssertEqual(controller.paletteItems(matching: "dark").map(\.title), ["Toggle Light/Dark"])
        XCTAssertEqual(controller.paletteItems(matching: "go pages").map(\.title), ["Go to All Pages"])
        XCTAssertEqual(controller.paletteItems(matching: "zzz").map(\.title), [])
    }
}
