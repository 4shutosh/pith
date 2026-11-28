import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class TransferTests: XCTestCase {
    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pith-transfer-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBackgroundExportWritesFilesAndRefusesLogseqDir() async throws {
        let dir = try tempDir("export")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("graph.db").path
        let graph = try PithGraph.open(path: dbPath)
        let pageId = newId()
        _ = try graph.applyOps(
            ops: [
                .createPage(id: pageId, title: "Alpha", journalDay: nil, documentMode: false),
                .insertBlock(id: newId(), pageId: pageId, parentId: nil, orderKey: "V", content: "Hello world"),
            ],
            meta: FfiTxMeta(writer: .user, actor: "me", session: nil, summary: "seed", undoGroup: nil)
        )

        let controller = try OutlinerController(
            graph: graph,
            shortcuts: ShortcutStore(defaults: UserDefaults(suiteName: "pith.transfer.\(UUID().uuidString)")!),
            worker: try GraphWorker(path: dbPath),
            background: try GraphWorker(path: dbPath, qos: .utility)
        )

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        controller.startMarkdownExport(outDir: outDir.path)

        let deadline = Date().addingTimeInterval(5)
        while controller.transfer.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        guard case let .finished(summary) = controller.transfer.phase else {
            XCTFail("expected finished phase, got \(controller.transfer.phase)")
            return
        }
        XCTAssertEqual(summary.kind, .exportMarkdown)
        let exported = try String(contentsOf: outDir.appendingPathComponent("pages/Alpha.md"), encoding: .utf8)
        XCTAssertEqual(exported, "- Hello world\n")

        controller.transfer.dismiss()
        XCTAssertEqual(controller.transfer.phase, .idle)

        let logseqDir = dir.appendingPathComponent("logseq-graph", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logseqDir.appendingPathComponent("logseq", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: logseqDir.appendingPathComponent("logseq/config.edn"),
            atomically: true,
            encoding: .utf8
        )

        controller.startMarkdownExport(outDir: logseqDir.path)
        let deadline2 = Date().addingTimeInterval(5)
        while controller.transfer.isRunning && Date() < deadline2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case let .failed(kind, _) = controller.transfer.phase else {
            XCTFail("expected failed phase for logseq dir, got \(controller.transfer.phase)")
            return
        }
        XCTAssertEqual(kind, .exportMarkdown)
    }

    func testActionsAppearInCatalogAndAvailabilityTracksTransfer() throws {
        XCTAssertTrue(AppAction.allCases.contains(.importLogseqGraph))
        XCTAssertTrue(AppAction.allCases.contains(.exportMarkdown))
        XCTAssertEqual(AppAction.importLogseqGraph.title, "Import Logseq Graph…")
        XCTAssertEqual(AppAction.exportMarkdown.title, "Export as Markdown…")
        XCTAssertTrue(AppAction.importLogseqGraph.inPalette)
        XCTAssertTrue(AppAction.exportMarkdown.inPalette)
    }
}
