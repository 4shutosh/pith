import PithCore
import PithMacCore
import XCTest

@MainActor
final class NewPageTests: XCTestCase {
    private func controllerOnOrigin() throws -> (PithGraph, OutlinerController, String) {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        controller.openPageByTitle("Origin")
        return (graph, controller, try XCTUnwrap(controller.selectedPageId))
    }

    func testANewPageWritesNothingUntilItIsUsed() throws {
        let (graph, controller, origin) = try controllerOnOrigin()
        let before = try graph.changeCursor()

        controller.perform(.newPage)
        XCTAssertTrue(controller.isNewUnsavedPage)
        XCTAssertTrue(controller.isEditingTitle)
        XCTAssertEqual(controller.pageTitle, "Untitled")
        XCTAssertNil(controller.selectedPageId)
        XCTAssertNil(try graph.getPageByTitle(title: "Untitled"))
        XCTAssertEqual(try graph.changeCursor(), before)

        controller.createNewBlankPage()
        XCTAssertEqual(controller.pageTitle, "Untitled")

        controller.goBack()
        XCTAssertEqual(controller.selectedPageId, origin)
        XCTAssertFalse(controller.isNewUnsavedPage)
        XCTAssertFalse(controller.isEditingTitle)
        XCTAssertFalse(controller.canGoForward)
        XCTAssertEqual(try graph.changeCursor(), before)
    }

    func testWritingTheFirstBlockSavesThePageAndOneUndoRemovesIt() throws {
        let (graph, controller, _) = try controllerOnOrigin()
        controller.createNewBlankPage()
        controller.ensureFirstBlockAndFocus()

        let page = try XCTUnwrap(graph.getPageByTitle(title: "Untitled"))
        XCTAssertEqual(controller.selectedPageId, page.id)
        XCTAssertFalse(controller.isNewUnsavedPage)
        XCTAssertEqual(controller.rows.count, 1)
        XCTAssertNotNil(controller.focusedBlockId)

        controller.blurFocus()
        controller.undo()
        XCTAssertNil(try graph.getPageByTitle(title: "Untitled"))
    }

    func testNamingANewPageSavesItOrOpensTheExistingPage() throws {
        let (graph, controller, origin) = try controllerOnOrigin()
        controller.createNewBlankPage()
        controller.renameCurrentPage(to: "  Draft notes ")
        let draft = try XCTUnwrap(graph.getPageByTitle(title: "Draft notes"))
        XCTAssertEqual(controller.selectedPageId, draft.id)
        XCTAssertFalse(controller.isNewUnsavedPage)

        controller.createNewBlankPage()
        controller.renameCurrentPage(to: "")
        XCTAssertTrue(controller.isNewUnsavedPage)
        controller.renameCurrentPage(to: "Origin")
        XCTAssertEqual(controller.selectedPageId, origin)
        XCTAssertEqual(controller.library.count, 2)
    }

    func testTheUntitledNameSkipsTakenTitles() throws {
        let (_, controller, _) = try controllerOnOrigin()
        controller.createNewBlankPage()
        controller.ensureFirstBlockAndFocus()
        controller.createNewBlankPage()
        XCTAssertEqual(controller.pageTitle, "Untitled 2")
    }
}
