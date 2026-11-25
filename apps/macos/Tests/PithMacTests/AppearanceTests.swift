import AppKit
import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class AppearanceTests: XCTestCase {
    func testBundledFontsRegisterAndResolveByFamily() {
        XCTAssertEqual(Typography.registerBundledFonts(), [])
        XCTAssertEqual(NSFontManager.shared.font(withFamily: "Inter", traits: [], weight: 5, size: 15)?.familyName, "Inter")
        XCTAssertEqual(NSFontManager.shared.font(withFamily: "JetBrains Mono", traits: [], weight: 5, size: 13)?.familyName, "JetBrains Mono")
        XCTAssertEqual(Typography.nsSans(15).familyName, "Inter")
    }

    func testTaskStatesMapToStatusIcons() {
        XCTAssertEqual(TaskStatus(state: "TODO"), .todo)
        XCTAssertEqual(TaskStatus(state: "NOW"), .doing)
        XCTAssertEqual(TaskStatus(state: "WAITING"), .later)
        XCTAssertEqual(TaskStatus(state: "DONE"), .done)
        XCTAssertEqual(TaskStatus(state: "CANCELLED"), .canceled)
        XCTAssertNil(TaskStatus(state: "MAYBE"))
        XCTAssertTrue(TaskStatus.done.isClosed)
        XCTAssertFalse(TaskStatus.doing.isClosed)
    }

    func testATaskPrefixBecomesAStatusAndLeavesTheEditableText() {
        let editable = BlockPresentation.editable([
            .task(state: "DONE", source: "DONE"),
            .text(text: "  Ship "),
            .tag(pageId: "p", title: "core", source: "#core"),
        ])
        XCTAssertEqual(editable, EditableBlock(status: .done, prefix: "DONE  ", text: "Ship #core"))
    }

    func testABlockWithoutATaskIsEditedWhole() {
        let editable = BlockPresentation.editable([.text(text: "Plain "), .pageLink(pageId: "p", title: "Pith", source: "[[Pith]]")])
        XCTAssertEqual(editable, EditableBlock(status: nil, prefix: "", text: "Plain [[Pith]]"))
    }

    func testDisplayRunsShowLinksWithTheirBracketsSoTheTextNeverShifts() {
        let (status, runs) = BlockPresentation.runs([
            .text(text: "Read "),
            .pageLink(pageId: "p", title: "Atomic Habits", source: "[[Atomic Habits]]"),
            .text(text: " now"),
        ])
        XCTAssertNil(status)
        XCTAssertEqual(runs.map(\.display).joined(), "Read [[Atomic Habits]] now")
        XCTAssertEqual(runs.map(\.source).joined(), "Read [[Atomic Habits]] now")
        XCTAssertEqual(runs[2], DisplayRun(display: "Atomic Habits", source: "Atomic Habits", style: .link(pageId: "p")))
    }

    func testAClickMapsToTheSameSpotInTheEditedText() {
        let runs = [
            DisplayRun(display: "See ", source: "See ", style: .plain),
            DisplayRun(display: "the block", source: "((0190a6f0-0000-7000-8000-000000000001))", style: .blockRef),
            DisplayRun(display: " after", source: " after", style: .plain),
        ]
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 2, in: runs), 2)
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 5, in: runs), 4)
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 12, in: runs), 44)
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 15, in: runs), 46)
    }

    func testEditingHighlightsComeFromTheCoreTokenizer() {
        let storage = NSTextStorage(string: "Read [[Pith]] #core")
        BlockStyle.applyHighlights(to: storage, highlights: highlight(text: storage.string))
        let bracket = storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        let title = storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor
        let plain = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(bracket, NSColor(hex: 0x5D5F66))
        XCTAssertEqual(title, Theme.nsLink)
        XCTAssertEqual(plain, NSColor(hex: 0xE8E8EA))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, Theme.nsLink)
    }

    func testColumnHelpers() {
        XCTAssertEqual(TextOffsets.column(ofScalar: 13, in: "abc\ndefghij\nxy"), 1)
        XCTAssertEqual(TextOffsets.offsetInLastLine(atColumn: 1, in: "abc\ndef"), 5)
        XCTAssertEqual(TextOffsets.offsetInLastLine(atColumn: 9, in: "abc\ndef"), 7)
        XCTAssertEqual(TextOffsets.offsetInFirstLine(atColumn: 9, in: "abc\ndef"), 3)
    }

    func testRecentPagesAreNewestFirstAndCapped() {
        func page(_ title: String, _ updated: Int64) -> FfiPage {
            FfiPage(id: title, title: title, journalDay: nil, documentMode: false, version: 1, updatedAt: updated)
        }
        let pages = [page("Old", 10), page("Newest", 30), page("Middle", 20)]
        XCTAssertEqual(OutlinerController.recent(pages, limit: 2).map(\.title), ["Newest", "Middle"])
    }

    func testSidebarRoutesBetweenTodayAndAllPages() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)
        XCTAssertTrue(controller.isShowingToday)

        controller.showAllPages()
        XCTAssertTrue(controller.isShowingAllPages)
        XCTAssertFalse(controller.isShowingToday)

        controller.openTodayJournal()
        XCTAssertFalse(controller.isShowingAllPages)
        XCTAssertTrue(controller.isShowingToday)
    }

    func testTextIsVerticallyCentredInItsLine() {
        Typography.registerBundledFonts()
        let font = BlockStyle.font
        let natural = ceil(font.ascender - font.descender + font.leading)
        XCTAssertEqual(BlockStyle.glyphHeight, natural)
        XCTAssertEqual(BlockStyle.baselineOffset, ((24 - natural) / 2).rounded())
        XCTAssertGreaterThan(BlockStyle.baselineOffset, 0)
        XCTAssertEqual(BlockStyle.editingAttributes[.baselineOffset] as? CGFloat, BlockStyle.baselineOffset)
    }
}
