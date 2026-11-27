import AppKit
import PithCore
import PithMacCore
import XCTest

@MainActor
final class ShortcutRulesTests: XCTestCase {
    private func freshStore() throws -> ShortcutStore {
        ShortcutStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "shortcut-rules-\(UUID().uuidString)")))
    }

    func testAShiftedSymbolKeyIsReadAsItsBaseKey() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: ">", charactersIgnoringModifiers: ">",
            isARepeat: false, keyCode: 47
        ))
        let stroke = KeyStroke(event: event)
        XCTAssertEqual(stroke.key, .character("."))
        XCTAssertEqual(try freshStore().action(matching: stroke, in: .global), .collapseAll)
        XCTAssertEqual(KeyCombo(stroke: stroke)?.displayString, "⇧⌘.")
    }

    func testBindingsNeedACommandLikeModifierAndCannotTakeSystemShortcuts() throws {
        let store = try freshStore()
        XCTAssertEqual(store.problem(with: KeyCombo(.returnKey), for: .openPalette), .needsModifier)
        XCTAssertEqual(store.problem(with: KeyCombo(.character("x"), [.shift]), for: .bold), .needsModifier)
        XCTAssertEqual(store.problem(with: KeyCombo(.character("c"), [.command]), for: .toggleFavorite), .reservedBySystem("Copy"))
        XCTAssertEqual(store.problem(with: KeyCombo(.character("z"), [.command, .shift]), for: .bold), .reservedBySystem("Redo"))
        XCTAssertNil(store.problem(with: KeyCombo(.up, [.option]), for: .moveBlockUp))
        XCTAssertNil(store.problem(with: KeyCombo(.character("a"), [.command]), for: .selectAllBlocks))
        XCTAssertNil(store.problem(with: KeyCombo(.character("e"), [.control]), for: .openJournals))
    }

    func testThePaletteShowsOnlyTheStoreBindingIncludingNone() throws {
        let store = try freshStore()
        store.set(nil, for: .toggleFavorite)
        store.set(KeyCombo(.character("e"), [.command, .option]), for: .findInPage)
        let controller = try OutlinerController(graph: try PithGraph.openInMemory(), shortcuts: store)
        controller.openPageByTitle("Roadmap")
        let items = Dictionary(uniqueKeysWithValues: controller.paletteItems.map { ($0.action, $0.shortcut) })
        XCTAssertEqual(items[.toggleFavorite], .some(nil))
        XCTAssertEqual(items[.findInPage], .some("⌥⌘E"))
        XCTAssertEqual(items[.deletePage], .some(nil))
        XCTAssertNil(items[.openPalette])
        XCTAssertNil(items[.bold])
    }

    func testBuiltInKeysFilterByTitleContextAndKeys() {
        XCTAssertEqual(BuiltInKey.matching("indent").map(\.title), ["Indent", "Indent / outdent selected blocks"])
        XCTAssertEqual(BuiltInKey.matching("unstar").map(\.title), ["Star / unstar the highlighted page"])
        XCTAssertEqual(BuiltInKey.matching("palette close").map(\.title), ["Close"])
        XCTAssertEqual(BuiltInKey.matching("").count, BuiltInKey.all.count)
    }

    func testThePaletteFindsCommandsByTheWordsPeopleUse() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory(), shortcuts: try freshStore())
        controller.openPageByTitle("Roadmap")
        XCTAssertEqual(controller.paletteItems(matching: "theme").map(\.action), [.toggleTheme, .openSettings])
        XCTAssertEqual(controller.paletteItems(matching: "sidebar").map(\.action), [.toggleSidebar])
        XCTAssertEqual(controller.paletteItems(matching: "delete").map(\.action), [.deletePage])
        XCTAssertEqual(controller.paletteItems(matching: "back").map(\.action), [.goBack])
    }
}
