import AppKit
import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class ShortcutsTests: XCTestCase {
    private func freshStore() -> (ShortcutStore, UserDefaults, String) {
        let suite = "pith.shortcuts.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ShortcutStore(defaults: defaults, storageKey: "bindings")
        return (store, defaults, suite)
    }

    func testKeyComboFormatsModifiersInMacOrderAndMatchesKeyStroke() {
        let combo = KeyCombo(.character("p"), [.command, .shift, .option, .control])
        XCTAssertEqual(combo.keycaps, ["⌃", "⌥", "⇧", "⌘", "P"])
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘P")

        let matching = KeyStroke(keyCode: 35, characters: "p", modifiers: [.command, .shift, .option, .control])
        let wrongMod = KeyStroke(keyCode: 35, characters: "p", modifiers: [.command])
        XCTAssertTrue(combo.matches(matching))
        XCTAssertFalse(combo.matches(wrongMod))
    }

    func testBareCharacterKeyIsRejectedWhileModifiedKeyIsAccepted() {
        let bare = KeyStroke(keyCode: 0, characters: "a", modifiers: [])
        XCTAssertNil(KeyCombo(stroke: bare))

        let modified = KeyStroke(keyCode: 0, characters: "a", modifiers: [.command])
        XCTAssertEqual(KeyCombo(stroke: modified), KeyCombo(.character("a"), [.command]))
    }

    func testCustomBindingsPersistUnbindAndReset() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(store.displayString(for: .openPalette), "⌘K")
        XCTAssertFalse(store.isCustomized(.openPalette))

        let custom = KeyCombo(.character("o"), [.command, .shift])
        store.set(custom, for: .openPalette)
        XCTAssertTrue(store.isCustomized(.openPalette))
        XCTAssertEqual(store.displayString(for: .openPalette), "⇧⌘O")

        store.set(nil, for: .toggleTheme)
        XCTAssertNil(store.combo(for: .toggleTheme))
        XCTAssertEqual(store.customizedCount, 2)

        let reloaded = ShortcutStore(defaults: defaults, storageKey: "bindings")
        XCTAssertEqual(reloaded.combo(for: .openPalette), custom)
        XCTAssertNil(reloaded.combo(for: .toggleTheme))
        XCTAssertEqual(reloaded.customizedCount, 2)

        reloaded.reset(.openPalette)
        XCTAssertEqual(reloaded.combo(for: .openPalette), try XCTUnwrap(AppAction.openPalette.defaultCombo))
        XCTAssertFalse(reloaded.isCustomized(.openPalette))

        reloaded.resetAll()
        XCTAssertFalse(reloaded.hasAnyCustomizations)
    }

    func testConflictsRespectScopeOverlapAndClearConflictsReplacesCleanly() throws {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let journalsCombo = try XCTUnwrap(AppAction.openJournals.defaultCombo)
        XCTAssertEqual(store.conflicts(for: journalsCombo, assigning: .openAllPages), [.openJournals])
        XCTAssertEqual(store.conflicts(for: journalsCombo, assigning: .bold), [.openJournals])

        let moveUpCombo = try XCTUnwrap(AppAction.moveBlockUp.defaultCombo)
        XCTAssertTrue(store.conflicts(for: moveUpCombo, assigning: .moveSelectionUp).isEmpty)

        store.set(journalsCombo, for: .openAllPages, clearConflicts: true)
        XCTAssertEqual(store.combo(for: .openAllPages), journalsCombo)
        XCTAssertNil(store.combo(for: .openJournals))
    }

    func testControllerShowsShortcutsScreenAndReflectsLiveBindingsInPalette() throws {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let graph = try PithGraph.openInMemory()
        let controller = try OutlinerController(graph: graph, shortcuts: store)

        controller.showShortcuts()
        XCTAssertEqual(controller.listScreen, .shortcuts)
        XCTAssertEqual(controller.sidebarDestination, .shortcuts)
        XCTAssertTrue(controller.canGoBack)

        store.set(KeyCombo(.character("?"), [.command, .shift]), for: .openShortcuts)
        let item = controller.paletteItems.first(where: { $0.action == .openShortcuts })
        XCTAssertEqual(item?.shortcut, "⇧⌘?")

        controller.goBack()
        XCTAssertNil(controller.listScreen)
    }
}
