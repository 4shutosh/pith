import PithCore
import PithMacCore
import XCTest

final class BacklinkGroupsTests: XCTestCase {
    private func link(_ block: String, page: String, title: String) -> FfiBacklink {
        FfiBacklink(blockId: block, pageId: page, pageTitle: title, kind: "page", renderedContent: block, spans: [.text(text: block)])
    }

    func testReferencesGroupUnderTheirPageInFirstSeenOrder() {
        let groups = BacklinkGroups.group([
            link("a1", page: "p-a", title: "2026-11-26"),
            link("b1", page: "p-b", title: "Pith"),
            link("a2", page: "p-a", title: "2026-11-26"),
            link("c1", page: "p-c", title: "Roadmap"),
            link("b2", page: "p-b", title: "Pith"),
        ])
        XCTAssertEqual(groups.map(\.pageTitle), ["2026-11-26", "Pith", "Roadmap"])
        XCTAssertEqual(groups.map { $0.backlinks.map(\.blockId) }, [["a1", "a2"], ["b1", "b2"], ["c1"]])
    }

    func testNoReferencesMakeNoGroups() {
        XCTAssertEqual(BacklinkGroups.group([]), [])
    }
}
