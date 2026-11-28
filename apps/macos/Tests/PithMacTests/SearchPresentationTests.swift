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

    func testSearchShowsTheLineThatMatchedWithTheQueryHighlighted() async throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        controller.ensureFirstBlockAndFocus()
        let id = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: id, text: "The Rust Programming Language\n\nHello, Cargo!", isComposing: false)
        controller.flushDraft()

        await controller.runSearch("cargo").value

        guard case let .block(_, _, _, _, breadcrumb, snippet, _, _)? = controller.search.hits.first else {
            return XCTFail("expected a block hit, got \(controller.search.hits)")
        }
        XCTAssertEqual(breadcrumb, [try XCTUnwrap(controller.pageTitle)])
        XCTAssertEqual(snippet, [
            FfiSegment(text: "Hello, ", highlighted: false),
            FfiSegment(text: "Cargo", highlighted: true),
            FfiSegment(text: "!", highlighted: false),
        ])
    }
}
