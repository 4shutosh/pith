import Combine
import PithCore
import PithMacCore
import XCTest

@MainActor
final class ObservationTests: XCTestCase {
    private var bag: Set<AnyCancellable> = []
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    override func tearDown() async throws {
        bag.removeAll()
    }

    private func seeded() throws -> (OutlinerController, [String]) {
        let graph = try PithGraph.openInMemory()
        let pageId = newId()
        var ops: [FfiOp] = [.createPage(id: pageId, title: "Notes", journalDay: nil, documentMode: false)]
        var ids: [String] = []
        var key: String?
        for line in ["alpha one", "beta", "alpha two alpha"] {
            let next = try orderKeyBetween(lower: key, upper: nil)
            let id = newId()
            ops.append(.insertBlock(id: id, pageId: pageId, parentId: nil, orderKey: next, content: line))
            ids.append(id)
            key = next
        }
        _ = try graph.applyOps(ops: ops, meta: setup)
        let controller = try OutlinerController(graph: graph)
        controller.selectPage(pageId)
        return (controller, ids)
    }

    private func counter(_ publisher: ObservableObjectPublisher) -> () -> Int {
        var count = 0
        publisher.sink { count += 1 }.store(in: &bag)
        return { count }
    }

    func testTypingInThePaletteNeverRepublishesTheOutline() async throws {
        let (controller, _) = try seeded()
        let outline = counter(controller.objectWillChange)
        let palette = counter(controller.search.objectWillChange)

        for query in ["a", "al", "alp", "alpha"] {
            await controller.runSearch(query).value
        }

        XCTAssertEqual(outline(), 0)
        XCTAssertGreaterThan(palette(), 0)
        XCTAssertEqual(controller.search.query, "alpha")
    }

    func testPageCountsArrivingInTheBackgroundNeverRepublishTheOutline() async throws {
        let (controller, _) = try seeded()
        let outline = counter(controller.objectWillChange)
        await controller.refreshPageSummaries().value
        XCTAssertEqual(outline(), 0)
        XCTAssertTrue(controller.directory.isLoaded)
    }

    func testTypingInFindNeverRepublishesTheOutline() throws {
        let (controller, _) = try seeded()
        controller.openFind()
        let outline = counter(controller.objectWillChange)

        controller.updateFindQuery("alp")
        controller.updateFindQuery("alpha")
        controller.nextFindMatch()

        XCTAssertEqual(outline(), 0)
        XCTAssertEqual(controller.find.matches.count, 3)
    }

    func testMatchesAreIndexedPerBlockWithOrdinalsInsideTheBlock() throws {
        let (controller, ids) = try seeded()
        controller.openFind()
        controller.updateFindQuery("alpha")

        XCTAssertEqual(controller.find.matches(in: ids[0]).map(\.start), [0])
        XCTAssertEqual(controller.find.matches(in: ids[1]), [])
        XCTAssertEqual(controller.find.matches(in: ids[2]).map(\.start), [0, 10])
        XCTAssertEqual(controller.find.activeOrdinal(in: ids[0]), 0)
        XCTAssertNil(controller.find.activeOrdinal(in: ids[2]))

        controller.nextFindMatch()
        controller.nextFindMatch()
        XCTAssertNil(controller.find.activeOrdinal(in: ids[0]))
        XCTAssertEqual(controller.find.activeOrdinal(in: ids[2]), 1)

        controller.closeFind()
        XCTAssertEqual(controller.find.matches(in: ids[2]), [])
    }

    func testNavigatingWithFindClosedPublishesNothingOnFind() throws {
        let (controller, _) = try seeded()
        let find = counter(controller.find.objectWillChange)
        controller.openPageByTitle("Elsewhere")
        controller.goBack()
        XCTAssertEqual(find(), 0)
    }

    func testBlockReferenceSuggestionsArriveFromTheWorkerAndSkipTheEditedBlock() async throws {
        let (controller, ids) = try seeded()
        controller.focusBlock(ids[0])
        let text = "alpha one ((alpha"
        controller.updateDraft(blockId: ids[0], text: text, isComposing: false, caret: text.count)
        await controller.completionSettled()

        let suggested = try XCTUnwrap(controller.completion).items.map(\.value)
        XCTAssertEqual(suggested, [ids[2]])
    }

    func testABlockSuggestionThatArrivesAfterDismissIsDropped() async throws {
        let (controller, ids) = try seeded()
        controller.focusBlock(ids[1])
        let text = "see ((alpha"
        controller.updateDraft(blockId: ids[1], text: text, isComposing: false, caret: text.count)
        controller.dismissCompletion()
        await controller.completionSettled()

        XCTAssertNil(controller.completion)
    }
}
