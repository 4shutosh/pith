import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class SearchPresentationTests: XCTestCase {
    func testBreadcrumbShowsShortPathsInFull() {
        XCTAssertEqual(SearchPresentation.breadcrumb(["Brink", "Android SDK", "Things to do"]), "Brink / Android SDK / Things to do")
    }

    func testBreadcrumbCollapsesTheMiddleOfLongPaths() {
        XCTAssertEqual(SearchPresentation.breadcrumb(["DSA Notes", "Questions", "Memory", "NEW: colouring"]), "DSA Notes / … / NEW: colouring")
    }

    func testCreatePageIsOfferedUnlessAPageHasExactlyThatTitle() {
        let exact: [FfiSearchHit] = [.page(pageId: "p", title: "Manage", highlightedTitle: [])]
        let partial: [FfiSearchHit] = [.page(pageId: "p", title: "Management", highlightedTitle: [])]
        XCTAssertFalse(SearchPresentation.offersCreatePage(query: "manage", hits: exact))
        XCTAssertTrue(SearchPresentation.offersCreatePage(query: "manage", hits: partial))
        XCTAssertFalse(SearchPresentation.offersCreatePage(query: "  ", hits: []))
    }

    func testSearchShowsTheLineThatMatchedWithTheQueryHighlighted() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        controller.ensureFirstBlockAndFocus()
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: id, text: "The Rust Programming Language\n\nHello, Cargo!", isComposing: false)
        controller.flushDraft()

        controller.runSearch("cargo")

        guard case let .block(_, _, _, breadcrumb, snippet, _, _)? = controller.searchHits.first else {
            return XCTFail("expected a block hit, got \(controller.searchHits)")
        }
        XCTAssertEqual(breadcrumb, [try XCTUnwrap(controller.pageTitle)])
        XCTAssertEqual(snippet, [
            FfiSegment(text: "Hello, ", highlighted: false),
            FfiSegment(text: "Cargo", highlighted: true),
            FfiSegment(text: "!", highlighted: false),
        ])
    }
}
