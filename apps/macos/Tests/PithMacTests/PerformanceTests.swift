import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class PerformanceTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)
    private let words = ["cargo", "rust", "notes", "agent", "outline", "journal", "search", "block", "sqlite", "swift"]

    private struct Stat {
        let name: String
        let p50: Double
        let p95: Double
        let budget: Double
    }

    private func measure(_ name: String, budget: Double, runs: Int = 30, _ body: (Int) throws -> Void) rethrows -> Stat {
        var samples: [Double] = []
        for run in 0..<runs {
            let start = ContinuousClock.now
            try body(run)
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        return Stat(
            name: name,
            p50: samples[samples.count / 2],
            p95: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))],
            budget: budget
        )
    }

    private func sentence(_ seed: Int) -> String {
        let rare = (0..<6).map { "term\(($0 * 7919 + seed * 104_729) % 2000)" }
        return (rare + [words[seed % words.count]]).joined(separator: " ")
    }

    private func appendBlocks(_ graph: PithGraph, pageId: String, count: Int, seed: Int) throws {
        var key: String? = nil
        var batch: [FfiOp] = []
        for i in 0..<count {
            key = try orderKeyBetween(lower: key, upper: nil)
            batch.append(.insertBlock(id: newId(), pageId: pageId, parentId: nil, orderKey: key!, content: sentence(seed + i)))
            if batch.count == 1000 {
                _ = try graph.applyOps(ops: batch, meta: setup)
                batch.removeAll()
            }
        }
        if !batch.isEmpty {
            _ = try graph.applyOps(ops: batch, meta: setup)
        }
    }

    private func seed(_ graph: PithGraph) throws -> String {
        for page in 0..<200 {
            let id = newId()
            _ = try graph.applyOps(ops: [.createPage(id: id, title: "Topic \(page)", journalDay: nil, documentMode: false)], meta: setup)
            try appendBlocks(graph, pageId: id, count: 240, seed: page)
        }
        let longId = newId()
        _ = try graph.applyOps(ops: [.createPage(id: longId, title: "Long page", journalDay: nil, documentMode: false)], meta: setup)
        try appendBlocks(graph, pageId: longId, count: 3000, seed: 7)
        for day in 1...60 {
            let date = String(format: "2020-%02d-%02d", (day - 1) / 28 + 1, (day - 1) % 28 + 1)
            let outcome = try graph.startJournal(date: date, meta: setup)
            _ = try graph.applyOps(ops: [.updateBlock(id: outcome.focusBlockId, content: sentence(day), expectedVersion: nil)], meta: setup)
            try appendBlocks(graph, pageId: try XCTUnwrap(graph.journalPage(date: date)).id, count: 25, seed: day)
        }
        return longId
    }

    func testEditorLatenciesOnALargeGraph() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PITH_PERF"] == "1", "set PITH_PERF=1 to run")
        let path = NSTemporaryDirectory() + "pith-perf-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let graph = try PithGraph.open(path: path)
        let seedStart = ContinuousClock.now
        let longId = try seed(graph)
        let seedTime = ContinuousClock.now - seedStart
        let controller = try OutlinerController(graph: graph)
        controller.debounceNanoseconds = 60_000_000_000

        var stats: [Stat] = []
        stats.append(try measure("launch → journals stream", budget: 300, runs: 10) { _ in
            _ = try OutlinerController(graph: graph)
        })
        stats.append(measure("open journals stream (⌘J)", budget: 50) { _ in
            controller.selectPage(longId)
            controller.openTodayJournal()
        })
        XCTAssertEqual(controller.journalSections.count, 8)
        stats.append(measure("open 3,000-block page", budget: 50) { _ in
            controller.openTodayJournal()
            controller.selectPage(longId)
        })
        XCTAssertEqual(controller.rows.count, 500)
        stats.append(measure("load next 500 rows", budget: 50, runs: 5) { _ in
            controller.loadMoreRows()
        })
        controller.selectPage(longId)
        let ids = controller.rows.prefix(60).map(\.id)
        stats.append(measure("focus switch", budget: 16) { run in
            controller.focusBlock(ids[run % ids.count])
        })
        controller.focusBlock(ids[0])
        stats.append(measure("keystroke save", budget: 16) { run in
            controller.updateDraft(blockId: ids[0], text: "edit \(run) " + sentence(run), isComposing: false)
            controller.flushDraft()
        })
        stats.append(measure("autocomplete [[ query", budget: 16) { run in
            let text = "see [[Topic \(run % 9)"
            controller.updateDraft(blockId: ids[0], text: text, isComposing: false, caret: text.count)
        })
        XCTAssertFalse(controller.completion?.items.isEmpty ?? true)
        controller.dismissCompletion()
        stats.append(measure("search: typical word", budget: 30) { run in
            controller.runSearch("term\(run * 37 % 2000)")
        })
        XCTAssertFalse(controller.searchHits.isEmpty)
        stats.append(measure("search: word in 10% of blocks", budget: 30) { run in
            controller.runSearch(words[run % words.count])
        })
        controller.blurFocus()
        stats.append(measure("toggle collapse", budget: 16, runs: 20) { _ in
            controller.toggleCollapse(ids[1])
        })

        let header = String(format: "Seeded %d blocks in %.1f s", 200 * 240 + 3000 + 60 * 26, Double(seedTime.components.seconds))
        var report = ["", header, "metric                         p50 ms   p95 ms   budget"]
        for stat in stats {
            let name = stat.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            report.append(String(format: "%@ %7.2f  %7.2f   < %.0f %@", name, stat.p50, stat.p95, stat.budget, stat.p95 < stat.budget ? "ok" : "OVER"))
        }
        print(report.joined(separator: "\n"))
        for stat in stats {
            XCTAssertLessThan(stat.p95, stat.budget, stat.name)
        }
    }
}
