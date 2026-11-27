import PithCore
import XCTest

@MainActor
struct RowFixture {
    static let meta = FfiTxMeta(writer: .user, actor: "fixture", session: nil, summary: "fixture", undoGroup: nil)
    let graph: PithGraph
    let pageId: String
    private var lastKey: String?

    init() throws {
        graph = try PithGraph.openInMemory()
        pageId = newId()
        _ = try graph.applyOps(
            ops: [.createPage(id: pageId, title: "Fixture", journalDay: nil, documentMode: false)],
            meta: Self.meta
        )
    }

    mutating func add(_ content: String) throws -> String {
        let id = newId()
        let key = try orderKeyBetween(lower: lastKey, upper: nil)
        lastKey = key
        _ = try graph.applyOps(
            ops: [.insertBlock(id: id, pageId: pageId, parentId: nil, orderKey: key, content: content)],
            meta: Self.meta
        )
        return id
    }

    func row(_ id: String) throws -> FfiFlatBlockRow {
        try XCTUnwrap(graph.blockRow(blockId: id))
    }

    mutating func row(for content: String) throws -> FfiFlatBlockRow {
        try row(add(content))
    }
}
