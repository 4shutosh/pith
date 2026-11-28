import AppKit
import Foundation
import PithCore
import PithMacCore
import XCTest

private func day(_ iso: String) -> JournalDay {
    guard let day = JournalDay(iso: iso) else {
        preconditionFailure("bad test date \(iso)")
    }
    return day
}

private func entry(_ iso: String, blocks: UInt32) -> FfiJournalDay {
    FfiJournalDay(date: iso, pageId: "page-\(iso)", blockCount: blocks)
}

final class JournalCalendarModelTests: XCTestCase {
    func testMonthsLayOutMondayFirstWeeksWithBlanksNotNeighbourDays() {
        let november = JournalMonth(year: 2026, month: 11)
        XCTAssertEqual(november.title, "November 2026")
        XCTAssertEqual(november.leadingBlanks, 6)
        XCTAssertEqual(november.days.count, 30)
        XCTAssertEqual(november.weeks.count, 6)
        XCTAssertEqual(november.weeks[0], [nil, nil, nil, nil, nil, nil, day("2026-11-01")])
        XCTAssertEqual(november.weeks[5], [day("2026-11-30"), nil, nil, nil, nil, nil, nil])

        let leap = JournalMonth(year: 2028, month: 2)
        XCTAssertEqual(leap.leadingBlanks, 1)
        XCTAssertEqual(leap.days.last, day("2028-02-29"))
        XCTAssertEqual(leap.weeks.count, 5)

        let plain = JournalMonth(year: 2027, month: 2)
        XCTAssertEqual(plain.leadingBlanks, 0)
        XCTAssertEqual(plain.days.count, 28)
        XCTAssertEqual(plain.weeks.count, 4)
    }

    func testDaysAndMonthsStepAcrossBoundaries() {
        XCTAssertEqual(day("2026-11-30").adding(days: 1), day("2026-12-01"))
        XCTAssertEqual(day("2026-01-01").adding(days: -1), day("2025-12-31"))
        XCTAssertEqual(day("2028-02-28").adding(days: 1), day("2028-02-29"))
        XCTAssertEqual(day("2027-02-28").adding(days: 1), day("2027-03-01"))
        XCTAssertEqual(day("2026-01-31").adding(months: 1), day("2026-02-28"))
        XCTAssertEqual(day("2025-12-15").adding(months: 1), day("2026-01-15"))
        XCTAssertEqual(day("2026-11-28").days(since: day("2026-10-28")), 31)
        XCTAssertEqual(day("2026-11-28").weekdayName, "Saturday")
        XCTAssertEqual(JournalMonth(year: 2026, month: 13), JournalMonth(year: 2027, month: 1))
        XCTAssertEqual(JournalMonth(year: 2026, month: 0), JournalMonth(year: 2025, month: 12))
        XCTAssertNil(JournalDay(iso: "2026-02-30"))
        XCTAssertNil(JournalDay(iso: "2026-2-03"))
    }

    func testInkDeepensWithHowMuchWasWritten() {
        let expected: [(UInt32, JournalInk)] = [
            (0, .none), (1, .light), (2, .light), (3, .medium), (6, .medium),
            (7, .strong), (15, .strong), (16, .full), (83, .full),
        ]
        for (blocks, ink) in expected {
            XCTAssertEqual(JournalInk(blockCount: blocks), ink, "\(blocks) blocks")
        }
    }

    func testHistorySpansFromTheFirstEntryToTodayOrTheSelectedDay() {
        let history = JournalHistory([entry("2026-08-03", blocks: 2), entry("2026-11-02", blocks: 9)])
        let today = day("2026-11-28")
        XCTAssertEqual(history.months(today: today, selected: today).map(\.id), ["2026-11", "2026-10", "2026-09", "2026-08"])
        XCTAssertEqual(
            history.months(today: today, selected: day("2027-01-05")).map(\.id),
            ["2027-01", "2026-12", "2026-11", "2026-10", "2026-09", "2026-08"]
        )
        XCTAssertEqual(JournalHistory.empty.months(today: today, selected: today).map(\.id), ["2026-11"])
        XCTAssertEqual(history.ink(day("2026-11-02")), .strong)
        XCTAssertEqual(history.ink(day("2026-11-03")), .none)
        XCTAssertEqual(history.writtenCount(in: JournalMonth(year: 2026, month: 11)), 1)
        XCTAssertEqual(history.writtenCount(in: JournalMonth(year: 2026, month: 10)), 0)
    }

    func testStatsCountStreaksThatMayEndYesterday() {
        let days = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05", "2026-11-25", "2026-11-26", "2026-11-27"]
        let history = JournalHistory(days.map { entry($0, blocks: 1) })
        XCTAssertEqual(
            history.stats(today: day("2026-11-28")),
            JournalStats(writtenDays: 8, since: day("2026-09-01"), currentStreak: 3, longestStreak: 5)
        )
        XCTAssertEqual(history.stats(today: day("2026-11-29")).currentStreak, 0)
        let withToday = JournalHistory((days + ["2026-11-28"]).map { entry($0, blocks: 1) })
        XCTAssertEqual(withToday.stats(today: day("2026-11-28")).currentStreak, 4)
        XCTAssertEqual(JournalHistory.empty.stats(today: day("2026-11-28")), JournalStats(writtenDays: 0, since: nil, currentStreak: 0, longestStreak: 0))
    }

    func testRelativeLabels() {
        let today = day("2026-11-28")
        XCTAssertEqual(JournalRelative.label(today, today: today), "Today")
        XCTAssertEqual(JournalRelative.label(day("2026-11-27"), today: today), "Yesterday")
        XCTAssertEqual(JournalRelative.label(day("2026-11-29"), today: today), "Tomorrow")
        XCTAssertEqual(JournalRelative.label(day("2026-11-23"), today: today), "5 days ago")
        XCTAssertEqual(JournalRelative.label(day("2026-12-01"), today: today), "In 3 days")
    }

    func testKeysMoveByDayWeekMonthAndWrittenDay() {
        let history = JournalHistory([entry("2026-10-02", blocks: 1), entry("2026-11-20", blocks: 4)])
        let today = day("2026-11-28")
        var state = JournalCalendarState(selected: day("2026-11-30"))
        let steps: [(KeyStroke, String)] = [
            (KeyStroke(keyCode: 124), "2026-12-01"),
            (KeyStroke(keyCode: 126), "2026-11-24"),
            (KeyStroke(keyCode: 125), "2026-12-01"),
            (KeyStroke(keyCode: 123), "2026-11-30"),
            (KeyStroke(keyCode: 116), "2026-10-30"),
            (KeyStroke(keyCode: 121), "2026-11-30"),
            (KeyStroke(keyCode: 123, modifiers: [.option]), "2026-11-20"),
            (KeyStroke(keyCode: 123, modifiers: [.option]), "2026-10-02"),
            (KeyStroke(keyCode: 123, modifiers: [.option]), "2026-10-02"),
            (KeyStroke(keyCode: 124, modifiers: [.option]), "2026-11-20"),
            (KeyStroke(keyCode: 17, characters: "t"), "2026-11-28"),
        ]
        for (stroke, expected) in steps {
            XCTAssertEqual(state.handleKey(stroke, today: today, history: history), .moved)
            XCTAssertEqual(state.selected.iso, expected)
        }
        XCTAssertEqual(state.handleKey(KeyStroke(keyCode: 36), today: today, history: history), .open(today))
        XCTAssertNil(state.handleKey(KeyStroke(keyCode: 0, characters: "a"), today: today, history: history))
        XCTAssertEqual(KeyStroke(keyCode: 116).key, .pageUp)
        XCTAssertEqual(KeyStroke(keyCode: 121).key, .pageDown)
    }

    func testThePreviewSitsBesideTheMonthsOnlyWhenBothFit() {
        let wide = JournalCalendarLayout(width: 594)
        XCTAssertTrue(wide.showsSidePreview)
        XCTAssertEqual(wide.cell, 34)
        XCTAssertEqual(wide.gridWidth, 262)
        XCTAssertFalse(JournalCalendarLayout(width: 593).showsSidePreview)
        XCTAssertEqual(JournalCalendarLayout(width: 593).cell, 48)
        XCTAssertEqual(JournalCalendarLayout(width: 400).gridWidth, 360)
        XCTAssertEqual(JournalCalendarLayout(width: 316).cell, 41)
        XCTAssertEqual(JournalCalendarLayout(width: 316).gridWidth, 311)
    }
}

@MainActor
final class JournalCalendarControllerTests: XCTestCase {
    private let setup = FfiTxMeta(writer: .user, actor: "setup", session: nil, summary: "seed", undoGroup: nil)

    func testOpeningAnEmptyDateCreatesNoPageUntilTheUserWritesText() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        controller.debounceNanoseconds = 60_000_000_000

        controller.openJournal(date: "2026-12-15")
        XCTAssertEqual(try graph.listPages().count, 0)
        XCTAssertEqual(controller.pendingJournalTitle, "2026-12-15")
        XCTAssertEqual(controller.journalHistory(), .empty)

        controller.ensureFirstBlockAndFocus()
        let blockId = try XCTUnwrap(controller.focusedBlockId)
        controller.updateDraft(blockId: blockId, text: "First note", isComposing: false)
        controller.flushDraft()

        XCTAssertEqual(try graph.listPages().count, 1)
        let history = controller.journalHistory()
        XCTAssertEqual(history.days.keys.map(\.iso), ["2026-12-15"])
        XCTAssertEqual(history.entry(day("2026-12-15"))?.blockCount, 1)
    }

    func testHistoryComesFromTheCoreAndCountsOnlyWrittenBlocks() throws {
        let graph = try PithGraph.openInMemory()
        let written = try graph.startJournal(date: "2026-11-12", meta: setup)
        _ = try graph.applyOps(ops: [.updateBlock(id: written.focusBlockId, content: "hello", expectedVersion: nil)], meta: setup)
        _ = try graph.startJournal(date: "2026-11-13", meta: setup)

        let controller = try OutlinerController(graph: graph)
        let history = controller.journalHistory()
        XCTAssertEqual(history.days.keys.map(\.iso), ["2026-11-12"])
        XCTAssertEqual(history.entry(day("2026-11-12"))?.pageId, try graph.journalPage(date: "2026-11-12")?.id)
    }
}
