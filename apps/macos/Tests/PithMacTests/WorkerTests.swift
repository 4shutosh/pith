import PithCore
import PithMacCore
import XCTest

@MainActor
final class WorkerTests: XCTestCase {
    private var path = ""
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "pith-worker-\(UUID().uuidString).db"
    }

    override func tearDown() async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func controller() throws -> OutlinerController {
        try OutlinerController(
            graph: try PithGraph.open(path: path),
            worker: try GraphWorker(path: path),
            background: try GraphWorker(path: path, qos: .utility)
        )
    }

    private func createPage(_ graph: PithGraph, _ title: String) throws -> String {
        let id = newId()
        _ = try graph.applyOps(ops: [.createPage(id: id, title: title, journalDay: nil, documentMode: false)], meta: setup)
        return id
    }

    func testAllPagesCountsArriveFromTheWorker() async throws {
        let controller = try controller()
        _ = try createPage(controller.graph, "Alpha")
        _ = try createPage(controller.graph, "Beta")

        controller.showAllPages()
        XCTAssertFalse(controller.directory.isLoaded)
        await controller.refreshPageSummaries().value

        XCTAssertTrue(controller.directory.isLoaded)
        XCTAssertEqual(Set(controller.directory.summaries.map(\.page.title)), ["Alpha", "Beta"])
    }

    func testCountsArePrefetchedSoAllPagesOpensWithThem() async throws {
        let graph = try PithGraph.open(path: path)
        _ = try createPage(graph, "Alpha")
        let controller = try OutlinerController(
            graph: graph,
            worker: try GraphWorker(path: path),
            background: try GraphWorker(path: path, qos: .utility)
        )
        await controller.refreshPageSummaries().value
        _ = try createPage(controller.graph, "Beta")
        controller.applyChanges()

        controller.showAllPages()

        XCTAssertTrue(controller.directory.isLoaded)
        XCTAssertEqual(controller.directory.summaries.map(\.page.title), ["Alpha"])
        await controller.refreshPageSummaries().value
        XCTAssertEqual(Set(controller.directory.summaries.map(\.page.title)), ["Alpha", "Beta"])
    }

    func testTheNewestRequestWins() async throws {
        let controller = try controller()
        _ = try createPage(controller.graph, "Alpha")
        controller.showAllPages()
        let first = controller.refreshPageSummaries()
        _ = try createPage(controller.graph, "Beta")
        let second = controller.refreshPageSummaries()
        await first.value
        await second.value

        XCTAssertEqual(Set(controller.directory.summaries.map(\.page.title)), ["Alpha", "Beta"])
    }

    func testABulkWriteOnTheWorkerReachesTheViewThroughTheFeed() async throws {
        let controller = try controller()
        let pageId = try createPage(controller.graph, "Imported")
        controller.selectPage(pageId)
        let meta = setup

        try await controller.background.run { graph in
            var ops: [FfiOp] = []
            var key: String?
            for n in 0..<2500 {
                key = try orderKeyBetween(lower: key, upper: nil)
                ops.append(.insertBlock(id: newId(), pageId: pageId, parentId: nil, orderKey: key!, content: "line \(n)"))
            }
            _ = try graph.applyOps(ops: ops, meta: meta)
        }
        controller.pollExternalChanges()

        XCTAssertEqual(controller.totalVisible, 2500)
        XCTAssertEqual(controller.rows.first?.renderedContent, "line 0")
    }

    func testRapidQueriesSettleOnTheLastOne() async throws {
        let controller = try controller()
        _ = try createPage(controller.graph, "Alpha")
        _ = try createPage(controller.graph, "Alpine")
        _ = try createPage(controller.graph, "Beta")

        var last: Task<Void, Never>?
        for query in ["a", "al", "alp", "alpha"] {
            last = controller.runSearch(query)
        }
        await last?.value

        XCTAssertEqual(controller.search.query, "alpha")
        XCTAssertEqual(controller.search.pageHits.count, 1)
        guard case let .page(_, title, _)? = controller.search.pageHits.first else {
            return XCTFail("expected the Alpha page")
        }
        XCTAssertEqual(title, "Alpha")
    }
}
