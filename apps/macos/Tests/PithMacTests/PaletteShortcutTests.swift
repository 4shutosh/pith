import AppKit
import PithCore
import PithMacCore
import XCTest

@MainActor
final class PaletteShortcutTests: XCTestCase {
    private func freshStore() throws -> ShortcutStore {
        ShortcutStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "palette-shortcuts-\(UUID().uuidString)")))
    }

    private func stroke(_ keyCode: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = []) -> KeyStroke {
        KeyStroke(keyCode: keyCode, characters: characters, modifiers: modifiers, isEditingText: true)
    }

    func testRecordingASingleKeyResolvesToOneOutcome() throws {
        let store = try freshStore()
        let favoriteDefault = KeyCombo(.character("d"), [.command])

        XCTAssertEqual(store.record(stroke(53, "\u{1B}"), for: .toggleFavorite), .cancelled)
        XCTAssertEqual(store.combo(for: .toggleFavorite), favoriteDefault)

        XCTAssertEqual(store.record(stroke(0, "a"), for: .toggleFavorite), .ignored)
        XCTAssertEqual(store.record(stroke(36, "\r"), for: .toggleFavorite), .rejected(KeyCombo(.returnKey), .needsModifier))
        XCTAssertEqual(
            store.record(stroke(8, "c", [.command]), for: .toggleFavorite),
            .rejected(KeyCombo(.character("c"), [.command]), .reservedBySystem("Copy"))
        )
        XCTAssertEqual(
            store.record(stroke(38, "j", [.command]), for: .toggleFavorite),
            .conflict(KeyCombo(.character("j"), [.command]), [.openJournals])
        )
        XCTAssertEqual(store.combo(for: .toggleFavorite), favoriteDefault)

        let chosen = KeyCombo(.character("f"), [.control, .option])
        XCTAssertEqual(store.record(stroke(3, "f", [.control, .option]), for: .toggleFavorite), .bound(chosen))
        XCTAssertEqual(store.combo(for: .toggleFavorite), chosen)
        XCTAssertTrue(store.isCustomized(.toggleFavorite))

        XCTAssertEqual(store.record(stroke(51, "\u{7F}"), for: .toggleFavorite), .cleared)
        XCTAssertNil(store.combo(for: .toggleFavorite))
    }

    func testShortcutSearchGroupsEveryActionByCategoryInCatalogOrder() throws {
        let store = try freshStore()
        let all = store.sections(matching: "")
        XCTAssertEqual(all.map(\.category), [.navigation, .page, .editing, .selection, .window])
        XCTAssertEqual(all.first?.actions.prefix(3), [.openPalette, .goToToday, .openJournals])
        XCTAssertTrue(all.flatMap(\.actions).contains(.bold))

        let favorite = store.sections(matching: "favorite")
        XCTAssertEqual(favorite.map(\.category), [.page])
        XCTAssertEqual(favorite.first?.actions, [.toggleFavorite])

        XCTAssertTrue(store.sections(matching: "zzzz").isEmpty)
    }

    func testCommandSlashSearchesShortcutsAndOptionCommandSlashOpensTheScreen() throws {
        let store = try freshStore()
        XCTAssertEqual(store.action(matching: stroke(44, "/", [.command]), in: .global), .searchShortcuts)
        XCTAssertEqual(store.action(matching: stroke(44, "/", [.command, .option]), in: .global), .openShortcuts)
        XCTAssertTrue(store.conflicts(for: KeyCombo(.character("/"), [.command]), assigning: .searchShortcuts).isEmpty)
    }

    func testSearchingShortcutsNeverNavigatesAwayFromThePage() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory(), shortcuts: try freshStore())
        controller.openPageByTitle("Roadmap")
        let page = controller.selectedPageId
        controller.perform(.searchShortcuts)
        XCTAssertNil(controller.listScreen)
        XCTAssertEqual(controller.selectedPageId, page)
        XCTAssertTrue(controller.isAvailable(.searchShortcuts))
    }
}
