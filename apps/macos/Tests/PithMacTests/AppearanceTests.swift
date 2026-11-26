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
        let color = { (index: Int) in storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(hex(color(5), in: .darkAqua), 0x5A554E)
        XCTAssertEqual(hex(color(7), in: .darkAqua), 0xE0A463)
        XCTAssertEqual(hex(color(0), in: .darkAqua), 0xDDD9D0)
        XCTAssertEqual(hex(color(14), in: .darkAqua), 0x84B59F)
        XCTAssertEqual(hex(color(5), in: .aqua), 0xB3ADA3)
        XCTAssertEqual(hex(color(7), in: .aqua), 0xA35F17)
        XCTAssertEqual(hex(color(0), in: .aqua), 0x2A2723)
        XCTAssertEqual(hex(color(14), in: .aqua), 0x3C7A5E)
    }

    func testThePaletteResolvesPerAppearance() {
        XCTAssertEqual(hex(Theme.nsCanvas, in: .darkAqua), 0x181715)
        XCTAssertEqual(hex(Theme.nsCanvas, in: .aqua), 0xFBFAF7)
        XCTAssertEqual(hex(Theme.nsTextStrong, in: .darkAqua), 0xF2EFE9)
        XCTAssertEqual(hex(Theme.nsTextStrong, in: .aqua), 0x1B1916)
        XCTAssertEqual(hex(Theme.nsCaret, in: .aqua), 0xA8641C)
    }

    func testThemeModesMapToAppearancesAndToggleFromTheCurrentLook() {
        XCTAssertNil(ThemeMode.system.appearance)
        XCTAssertEqual(ThemeMode.light.appearance?.name, .aqua)
        XCTAssertEqual(ThemeMode.dark.appearance?.name, .darkAqua)
        XCTAssertEqual(ThemeMode.toggled(currentlyDark: true), .light)
        XCTAssertEqual(ThemeMode.toggled(currentlyDark: false), .dark)
        XCTAssertEqual(ThemeMode(rawValue: "dark"), .dark)
        XCTAssertTrue(ThemeMode.isDark(NSAppearance(named: .darkAqua)!))
        XCTAssertFalse(ThemeMode.isDark(NSAppearance(named: .aqua)!))
    }

    private func hex(_ color: NSColor?, in name: NSAppearance.Name) -> UInt32? {
        guard let color, let appearance = NSAppearance(named: name) else { return nil }
        var value: UInt32?
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let channel = { (c: CGFloat) in UInt32((c * 255).rounded()) }
            value = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
        }
        return value
    }

    func testFormattingMarkersAreHiddenOutsideEditing() {
        let runs = BlockPresentation.runs([
            .text(text: "a "),
            .bold(text: "system", source: "**system**"),
            .text(text: " b "),
            .italic(text: "why", source: "*why*"),
        ]).runs
        XCTAssertEqual(runs.map(\.display).joined(), "a system b why")
        XCTAssertEqual(runs.map(\.source).joined(), "a **system** b *why*")
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 3, in: runs), 5)
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 8, in: runs), 10)
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 12, in: runs), 17)
    }

    func testBoldAndItalicRenderWithRealFaces() throws {
        XCTAssertEqual(Typography.registerBundledFonts(), [])
        let runs = BlockPresentation.runs([
            .bold(text: "big", source: "**big**"),
            .text(text: " "),
            .italic(text: "slant", source: "*slant*"),
        ]).runs
        let shown = BlockStyle.display(runs, closed: false)
        XCTAssertEqual(shown.string, "big slant")
        let boldFont = shown.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let italicFont = shown.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertEqual(boldFont?.familyName, "Inter")
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(boldFont)).contains(.boldFontMask))
        XCTAssertEqual(italicFont?.familyName, "Inter")
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(italicFont)).contains(.italicFontMask))
    }

    func testInlineCodeHidesItsBackticksOutsideEditing() {
        let runs = BlockPresentation.runs([.text(text: "run "), .code(text: "`cargo test`")]).runs
        XCTAssertEqual(runs.map(\.display).joined(), "run cargo test")
        XCTAssertEqual(runs.map(\.source).joined(), "run `cargo test`")
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 5, in: runs), 6)
        let unclosed = BlockPresentation.runs([.code(text: "``")]).runs
        XCTAssertEqual(unclosed.map(\.display).joined(), "``")
    }

    func testTheEditorColumnIsCentredInThePaneBesideTheSidebar() {
        XCTAssertEqual(EditorLayout.compute(windowWidth: 1280, sidebarOpen: true), EditorLayout(leading: 408.5, width: 680))
        XCTAssertEqual(EditorLayout.compute(windowWidth: 1280, sidebarOpen: false), EditorLayout(leading: 300, width: 680))
        XCTAssertEqual(EditorLayout.compute(windowWidth: 820, sidebarOpen: true), EditorLayout(leading: 281, width: 475))
        XCTAssertEqual(EditorLayout.compute(windowWidth: 600, sidebarOpen: true), EditorLayout(leading: 281, width: 320))
    }

    func testColumnHelpers() {
        XCTAssertEqual(TextOffsets.column(ofScalar: 13, in: "abc\ndefghij\nxy"), 1)
        XCTAssertEqual(TextOffsets.offsetInLastLine(atColumn: 1, in: "abc\ndef"), 5)
        XCTAssertEqual(TextOffsets.offsetInLastLine(atColumn: 9, in: "abc\ndef"), 7)
        XCTAssertEqual(TextOffsets.offsetInFirstLine(atColumn: 9, in: "abc\ndef"), 3)
    }

    func testRecentPagesAreNewestFirstAndCapped() {
        func page(_ title: String, _ updated: Int64) -> FfiPage {
            FfiPage(id: title, title: title, journalDay: nil, documentMode: false, favorite: false, version: 1, updatedAt: updated)
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
