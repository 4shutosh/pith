import Foundation
import PithCore
import XCTest

final class BridgeTests: XCTestCase {
    func testSwiftReadsEditsUndoesAndObservesChangeFeed() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pith-swift-bridge-\(UUID().uuidString).db")
            .path

        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }

        let app = try PithGraph.open(path: dbPath)
        let external = try PithGraph.open(path: dbPath)

        XCTAssertNil(try app.journalPage(date: "2026-11-25"))
        let journalId = newId()
        _ = try app.applyOps(
            ops: [.createPage(id: journalId, title: "Bridge test", journalDay: nil, documentMode: false)],
            meta: FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "setup", undoGroup: nil)
        )
        let journal = try XCTUnwrap(app.getPage(id: journalId))

        let b1 = newId()
        let b2 = newId()
        let k1 = try orderKeyBetween(lower: nil, upper: nil)
        let k2 = try orderKeyBetween(lower: k1, upper: nil)

        let meta = FfiTxMeta(
            writer: .user,
            actor: "me",
            session: nil,
            summary: "swift test insert",
            undoGroup: nil
        )
        _ = try app.applyOps(
            ops: [
                .insertBlock(
                    id: b1,
                    pageId: journal.id,
                    parentId: nil,
                    orderKey: k1,
                    content: "Hello [[SwiftBridge]] #macos"
                ),
                .insertBlock(
                    id: b2,
                    pageId: journal.id,
                    parentId: b1,
                    orderKey: k2,
                    content: "Nested child"
                ),
            ],
            meta: meta
        )

        let window = try app.readPageWindow(pageId: journal.id, offset: 0, limit: 50)
        XCTAssertEqual(window.totalVisible, 2)
        XCTAssertEqual(window.rows[0].renderedContent, "Hello [[SwiftBridge]] #macos")
        XCTAssertTrue(window.rows[0].hasChildren)
        XCTAssertEqual(window.rows[1].depth, 1)

        let hits = try app.search(query: "SwiftBridge", limit: 10)
        XCTAssertFalse(hits.isEmpty)

        let bridgePage = try XCTUnwrap(app.getPageByTitle(title: "SwiftBridge"))
        let backlinks = try app.backlinks(targetId: bridgePage.id)
        XCTAssertEqual(backlinks.count, 1)

        let seqBeforeExternal = try app.changesSince(afterSeq: 0, limit: 100).latestSeq
        let dvBeforeExternal = try app.dataVersion()

        let agentMeta = FfiTxMeta(
            writer: .agent,
            actor: "agent:claude",
            session: nil,
            summary: "agent edit",
            undoGroup: nil
        )
        _ = try external.applyOps(
            ops: [.updateBlock(id: b2, content: "Updated by agent", expectedVersion: 1)],
            meta: agentMeta
        )

        XCTAssertNotEqual(try app.dataVersion(), dvBeforeExternal)
        let feed = try app.changesSince(afterSeq: seqBeforeExternal, limit: 100)
        XCTAssertEqual(feed.entries.count, 1)
        XCTAssertEqual(feed.entries[0].actor, "agent:claude")
        XCTAssertTrue(feed.entries[0].touchedIds.contains(b2))

        _ = try app.undoLast(actor: "me", force: true)
        XCTAssertEqual(try app.readPageWindow(pageId: journal.id, offset: 0, limit: 50).totalVisible, 0)

        _ = try app.redoLast(actor: "me", force: true)
        XCTAssertEqual(try app.readPageWindow(pageId: journal.id, offset: 0, limit: 50).totalVisible, 2)
    }
}
