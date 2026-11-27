import AppKit
import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class SettingsTests: XCTestCase {
    private func freshSettings() -> (AppSettings, UserDefaults, String) {
        let suite = "pith.settings.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        return (settings, defaults, suite)
    }

    override func tearDown() {
        Theme.currentAccent = .amber
        Theme.currentSurface = .warm
        super.tearDown()
    }

    func testJournalDateFormatsRenderDeterministicallyAndLeaveNonDatesAlone() {
        XCTAssertEqual(JournalDateFormat.iso.format("2026-11-27"), "2026-11-27")
        XCTAssertEqual(JournalDateFormat.medium.format("2026-11-27"), "Nov 27, 2026")
        XCTAssertEqual(JournalDateFormat.weekday.format("2026-11-27"), "Fri, Nov 27, 2026")
        XCTAssertEqual(JournalDateFormat.dayFirst.format("2026-11-27"), "27 Nov 2026")

        XCTAssertEqual(JournalDateFormat.weekday.format("Roadmap"), "Roadmap")
        XCTAssertEqual(JournalDateFormat.medium.format("2026-02-30"), "2026-02-30")
    }

    func testSettingsPersistAccentDateFormatAndLinkBracketsAndResetCleanly() {
        let (settings, defaults, suite) = freshSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(settings.accent, .amber)
        XCTAssertEqual(settings.dateFormat, .iso)
        XCTAssertTrue(settings.showLinkBrackets)

        settings.accent = .cobalt
        settings.dateFormat = .weekday
        settings.showLinkBrackets = false
        XCTAssertEqual(Theme.currentAccent, .cobalt)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.accent, .cobalt)
        XCTAssertEqual(reloaded.dateFormat, .weekday)
        XCTAssertFalse(reloaded.showLinkBrackets)

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.accent, .amber)
        XCTAssertEqual(reloaded.dateFormat, .iso)
        XCTAssertTrue(reloaded.showLinkBrackets)
        XCTAssertEqual(Theme.currentAccent, .amber)
    }

    func testHidingLinkBracketsHidesOnlyDoubleBracketsAndPreservesEditOffsets() {
        let display = FfiBlockDisplay(
            taskState: nil,
            prefix: "",
            runs: [
                FfiDisplayRun(display: "See ", source: "See ", style: .plain),
                FfiDisplayRun(display: "[[", source: "[[", style: .marker),
                FfiDisplayRun(display: "Pith", source: "Pith", style: .link(pageId: "p1", deleted: false)),
                FfiDisplayRun(display: "]]", source: "]]", style: .marker),
            ]
        )
        let shown = BlockPresentation.runs(display, showLinkBrackets: true).runs
        XCTAssertEqual(shown.map(\.display).joined(), "See [[Pith]]")

        let hidden = BlockPresentation.runs(display, showLinkBrackets: false).runs
        XCTAssertEqual(hidden.map(\.display).joined(), "See Pith")
        XCTAssertEqual(hidden.map(\.source).joined(), "See [[Pith]]")
        XCTAssertEqual(BlockPresentation.editUTF16Offset(forDisplayUTF16: 6, in: hidden), 8)
    }

    func testControllerOpensSettingsAndPushesBackHistory() throws {
        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph)

        controller.showSettings()
        XCTAssertEqual(controller.listScreen, .settings)
        XCTAssertEqual(controller.sidebarDestination, .settings)
        XCTAssertTrue(controller.canGoBack)

        controller.goBack()
        XCTAssertNil(controller.listScreen)
    }

    func testAllAccentPalettesMeetWCAGContrastAcrossAllSurfaces() {
        func luminance(_ color: NSColor, in appearance: NSAppearance) -> Double {
            var result = 0.0
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = color.usingColorSpace(.sRGB) else { return }
                func lin(_ c: CGFloat) -> Double {
                    let v = Double(c)
                    return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                result = 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
            }
            return result
        }

        func contrast(_ fg: NSColor, on bg: NSColor, in appearance: NSAppearance) -> Double {
            let l1 = luminance(fg, in: appearance)
            let l2 = luminance(bg, in: appearance)
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }

        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!

        for surface in SurfaceStyle.allCases {
            Theme.currentSurface = surface
            for palette in AccentPalette.allCases {
                Theme.currentAccent = palette
                let darkRatio = contrast(Theme.nsLink, on: Theme.nsCanvas, in: dark)
                let darkSelectedRatio = contrast(Theme.nsLink, on: Theme.nsSelected, in: dark)
                let lightRatio = contrast(Theme.nsLink, on: Theme.nsCanvas, in: light)
                XCTAssertGreaterThanOrEqual(darkRatio, 7.0, "\(palette.label) on \(surface.label) dark canvas")
                XCTAssertGreaterThanOrEqual(darkSelectedRatio, 6.0, "\(palette.label) on \(surface.label) dark selected")
                XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "\(palette.label) on \(surface.label) light canvas")
            }
        }
    }
}
