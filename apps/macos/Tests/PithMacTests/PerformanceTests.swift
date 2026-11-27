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

    private func measureAsync(_ name: String, budget: Double, runs: Int, _ body: (Int) async throws -> Void) async rethrows -> Stat {
        var samples: [Double] = []
        for run in 0..<runs {
            let start = ContinuousClock.now
            try await body(run)
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

    func testEditorLatenciesOnALargeGraph() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PITH_PERF"] == "1", "set PITH_PERF=1 to run")
        let path = NSTemporaryDirectory() + "pith-perf-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let graph = try PithGraph.open(path: path)
        let seedStart = ContinuousClock.now
        let longId = try seed(graph)
        let seedTime = ContinuousClock.now - seedStart
        let controller = try OutlinerController(graph: graph, worker: try GraphWorker(path: path), background: try GraphWorker(path: path, qos: .utility))
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
        stats.append(await measureAsync("search: typical word", budget: 30, runs: 30) { run in
            await controller.runSearch("term\(run * 37 % 2000)").value
        })
        XCTAssertFalse(controller.search.hits.isEmpty)
        stats.append(await measureAsync("search: word in 10% of blocks", budget: 30, runs: 30) { run in
            await controller.runSearch(words[run % words.count]).value
        })
        controller.blurFocus()
        stats.append(measure("open All pages (main thread)", budget: 16, runs: 10) { _ in
            controller.showAllPages()
            controller.goBack()
        })
        controller.showAllPages()
        stats.append(await measureAsync("All pages counts (worker)", budget: 150, runs: 10) { _ in
            await controller.refreshPageSummaries().value
        })
        XCTAssertEqual(controller.directory.summaries.count, 200 + 1 + 60)
        controller.selectPage(longId)
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

    func testLibraryScaleLatencies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PITH_PERF"] == "1", "set PITH_PERF=1 to run")
        let path = NSTemporaryDirectory() + "pith-scale-\(UUID().uuidString).db"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let graph = try PithGraph.open(path: path)
        let agent = try PithGraph.open(path: path)
        let pageCount = 10_000
        var pageIds: [String] = []
        var batch: [FfiOp] = []
        for page in 0..<pageCount {
            let id = newId()
            pageIds.append(id)
            batch.append(.createPage(id: id, title: "Library \(page)", journalDay: nil, documentMode: false))
            var key: String?
            for line in 0..<10 {
                key = try orderKeyBetween(lower: key, upper: nil)
                let text = line == 0 && page > 0 ? "about Library \(page - 1) and [[Library \(page / 2)]]" : sentence(page * 10 + line)
                batch.append(.insertBlock(id: newId(), pageId: id, parentId: nil, orderKey: key!, content: text))
            }
            if page % 25 == 0 {
                batch.append(.setPageFavorite(id: id, favorite: page % 500 == 0))
            }
            if batch.count >= 2000 {
                _ = try graph.applyOps(ops: batch, meta: setup)
                batch.removeAll()
            }
        }
        _ = try graph.applyOps(ops: batch, meta: setup)

        var stats: [Stat] = []
        stats.append(try measure("launch with 10k pages", budget: 300, runs: 5) { _ in
            _ = try OutlinerController(graph: graph)
        })
        let controller = try OutlinerController(graph: graph, worker: try GraphWorker(path: path), background: try GraphWorker(path: path, qos: .utility))
        controller.selectPage(pageIds[42])
        XCTAssertEqual(controller.library.count, pageCount)
        stats.append(measure("sidebar favorites + recents", budget: 4) { _ in
            _ = controller.favoritePages
            _ = controller.recentPages
        })
        XCTAssertEqual(controller.favoritePages.count, 20)
        stats.append(measure("currentPage x100", budget: 1) { _ in
            for _ in 0..<100 { _ = controller.currentPage }
        })
        stats.append(try measure("external rename → refresh", budget: 50, runs: 10) { run in
            _ = try agent.applyOps(ops: [.renamePage(id: pageIds[9000], title: "Renamed \(run)", expectedVersion: nil)], meta: setup)
            controller.pollExternalChanges()
        })
        XCTAssertTrue(controller.library.contains { $0.title == "Renamed 9" })
        stats.append(measure("navigate between pages", budget: 16, runs: 20) { run in
            controller.selectPage(pageIds[run % 2 == 0 ? 100 : 200])
        })
        stats.append(await measureAsync("palette search", budget: 30, runs: 20) { run in
            await controller.runSearch("Library \(run * 431)").value
        })
        stats.append(measure("unlinked references", budget: 50, runs: 10) { _ in
            controller.loadUnlinkedReferences()
        })
        stats.append(measure("open All pages (main thread)", budget: 16, runs: 5) { _ in
            controller.showAllPages()
            controller.goBack()
        })
        let cold = try OutlinerController(graph: graph, worker: try GraphWorker(path: path), background: try GraphWorker(path: path, qos: .utility))
        stats.append(await measureAsync("first counts after launch", budget: 1000, runs: 1) { _ in
            await cold.refreshPageSummaries().value
        })
        controller.showAllPages()
        stats.append(await measureAsync("All pages counts (warm)", budget: 100, runs: 5) { _ in
            await controller.refreshPageSummaries().value
        })
        XCTAssertEqual(controller.directory.summaries.count, pageCount)
        let all = controller.directory.summaries
        stats.append(measure("All pages filter keystroke", budget: 16, runs: 20) { run in
            let query = String("library 42".prefix(run % 10 + 1))
            _ = PageDirectory.filter(all, tab: .pages, query: query, sort: .updated)
            for tab in PageDirectoryTab.allCases {
                _ = PageDirectory.count(in: all, for: tab)
            }
            _ = PageDirectory.offersCreate(query: query, in: all)
        })

        var report = ["", "Library: \(pageCount) pages, \(pageCount * 10) blocks", "metric                         p50 ms   p95 ms   budget"]
        for stat in stats {
            let name = stat.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            report.append(String(format: "%@ %7.2f  %7.2f   < %.0f %@", name, stat.p50, stat.p95, stat.budget, stat.p95 < stat.budget ? "ok" : "OVER"))
        }
        print(report.joined(separator: "\n"))
        for stat in stats {
            XCTAssertLessThan(stat.p95, stat.budget, stat.name)
        }
    }

    func testSeedAProfilingGraph() throws {
        guard let target = ProcessInfo.processInfo.environment["PITH_SEED_PATH"] else {
            throw XCTSkip("set PITH_SEED_PATH to write a profiling graph")
        }
        try? FileManager.default.removeItem(atPath: target)
        let graph = try PithGraph.open(path: target)
        let longId = try seed(graph)
        _ = try graph.applyOps(ops: [.renamePage(id: longId, title: "Profiling long page", expectedVersion: nil)], meta: setup)
        var batch: [FfiOp] = []
        for page in 0..<10_000 {
            let id = newId()
            batch.append(.createPage(id: id, title: "Library \(page)", journalDay: nil, documentMode: false))
            var key: String?
            for line in 0..<10 {
                key = try orderKeyBetween(lower: key, upper: nil)
                let text = line == 0 && page > 0 ? "about Library \(page - 1) and [[Library \(page / 2)]]" : sentence(page * 10 + line)
                batch.append(.insertBlock(id: newId(), pageId: id, parentId: nil, orderKey: key!, content: text))
            }
            if page % 500 == 0 {
                batch.append(.setPageFavorite(id: id, favorite: true))
            }
            if batch.count >= 2000 {
                _ = try graph.applyOps(ops: batch, meta: setup)
                batch.removeAll()
            }
        }
        _ = try graph.applyOps(ops: batch, meta: setup)
        let today = try graph.startJournal(date: nil, meta: setup)
        _ = try graph.applyOps(ops: [.updateBlock(id: today.focusBlockId, content: "today, see [[Profiling long page]]", expectedVersion: nil)], meta: setup)
    }
}
