import AppKit
import Foundation
import PithCore
import PithMacCore
import SwiftUI
import XCTest
@testable import PithMacApp

@MainActor
private final class HarnessState: ObservableObject {
    @Published var showSearch = false
    @Published var showSidebar = true
    @Published var sidebarCompact = false
    @Published var sidebarPeek = false
    @Published var themeMode: ThemeMode = .dark
}

private struct HarnessHostView: View {
    let controller: OutlinerController
    let shortcuts: ShortcutStore
    let keyRouter: KeyRouter
    @ObservedObject var state: HarnessState

    var body: some View {
        ContentView(
            controller: controller,
            shortcuts: shortcuts,
            showSearch: $state.showSearch,
            showSidebar: $state.showSidebar,
            sidebarCompact: $state.sidebarCompact,
            sidebarPeek: $state.sidebarPeek,
            themeMode: $state.themeMode,
            keyRouter: keyRouter,
            monitorSystemEvents: false
        )
    }
}

@MainActor
private final class AppKeyboardHarness {
    let graph: PithGraph
    let shortcuts: ShortcutStore
    let controller: OutlinerController
    let keyRouter: KeyRouter
    let state: HarnessState
    let window: NSWindow
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "pith.journey.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        shortcuts = ShortcutStore(defaults: defaults, storageKey: "bindings")
        graph = try PithGraph.openInMemory()
        controller = try OutlinerController(graph: graph, shortcuts: shortcuts)
        keyRouter = KeyRouter()
        state = HarnessState()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(
            rootView: HarnessHostView(
                controller: controller,
                shortcuts: shortcuts,
                keyRouter: keyRouter,
                state: state
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window.contentView = host
        window.layoutIfNeeded()
        pump()
    }

    func tearDown() {
        window.contentView = nil
        pump()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func pump(_ seconds: TimeInterval = 0.04) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    @discardableResult
    func press(_ combo: KeyCombo, editing: Bool = false, ime: Bool = false) -> Bool {
        let stroke = makeStroke(key: combo.key.key, modifiers: combo.modifiers.nsFlags, editing: editing, ime: ime)
        let handled = keyRouter.dispatch(stroke)
        pump()
        return handled
    }

    @discardableResult
    func press(
        _ key: Key,
        modifiers: NSEvent.ModifierFlags = [],
        editing: Bool = false,
        ime: Bool = false
    ) -> Bool {
        let stroke = makeStroke(key: key, modifiers: modifiers, editing: editing, ime: ime)
        let handled = keyRouter.dispatch(stroke)
        pump()
        return handled
    }

    private func makeStroke(
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        editing: Bool,
        ime: Bool
    ) -> KeyStroke {
        switch key {
        case .returnKey: return KeyStroke(keyCode: 36, characters: "\r", modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .escape: return KeyStroke(keyCode: 53, characters: "\u{1B}", modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .up: return KeyStroke(keyCode: 126, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .down: return KeyStroke(keyCode: 125, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .left: return KeyStroke(keyCode: 123, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .right: return KeyStroke(keyCode: 124, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .tab: return KeyStroke(keyCode: 48, characters: "\t", modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .backspace: return KeyStroke(keyCode: 51, characters: "\u{7F}", modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case .forwardDelete: return KeyStroke(keyCode: 117, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case let .character(ch): return KeyStroke(keyCode: 0, characters: ch, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        case let .other(code): return KeyStroke(keyCode: code, characters: nil, modifiers: modifiers, isEditingText: editing, isComposingIME: ime)
        }
    }
}

@MainActor
final class KeyboardJourneyTests: XCTestCase {
    private let setupMeta = FfiTxMeta(writer: .user, actor: "me", session: nil, summary: "seed", undoGroup: nil)

    func testNoDefaultShortcutsConflictInOverlappingScopes() {
        let suite = "pith.defaults.check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults, storageKey: "bindings")

        for action in AppAction.allCases {
            guard let combo = action.defaultCombo else { continue }
            let conflicts = store.conflicts(for: combo, assigning: action)
            XCTAssertEqual(conflicts, [], "Default shortcut \(combo.displayString) for \(action.rawValue) conflicts with \(conflicts)")
        }
    }

    func testRealWindowNavigatesAllScreensRebindsShortcutAndRespectsHistory() throws {
        let harness = try AppKeyboardHarness()
        defer { harness.tearDown() }

        let pageId = newId()
        _ = try harness.graph.applyOps(ops: [
            .createPage(id: pageId, title: "Roadmap", journalDay: nil, documentMode: false),
        ], meta: setupMeta)
        harness.controller.applyChanges()
        harness.pump()

        XCTAssertEqual(harness.keyRouter.registrationCount(in: .global), 1)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .screen), 1)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 0)

        let openAllPages = try XCTUnwrap(AppAction.openAllPages.defaultCombo)
        XCTAssertTrue(harness.press(openAllPages))
        XCTAssertEqual(harness.controller.listScreen, .allPages)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .screen), 1)

        XCTAssertTrue(harness.press(.down))
        XCTAssertTrue(harness.press(.character("s")))
        XCTAssertEqual(harness.controller.favoritePages.map(\.title), ["Roadmap"])

        let openShortcuts = try XCTUnwrap(AppAction.openShortcuts.defaultCombo)
        XCTAssertTrue(harness.press(openShortcuts))
        XCTAssertEqual(harness.controller.listScreen, .shortcuts)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .screen), 1)

        XCTAssertTrue(harness.press(.down))
        XCTAssertTrue(harness.press(.returnKey))
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 1)

        let rebound = KeyCombo(.character("k"), [.command, .option])
        XCTAssertTrue(harness.press(rebound))
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 0)
        XCTAssertEqual(harness.shortcuts.combo(for: .openPalette), rebound)

        let oldPalette = try XCTUnwrap(AppAction.openPalette.defaultCombo)
        XCTAssertFalse(harness.press(oldPalette))
        XCTAssertFalse(harness.state.showSearch)

        XCTAssertTrue(harness.press(rebound))
        XCTAssertTrue(harness.state.showSearch)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 1)

        XCTAssertTrue(harness.press(.escape))
        XCTAssertFalse(harness.state.showSearch)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 0)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.goBack.defaultCombo)))
        XCTAssertEqual(harness.controller.listScreen, .allPages)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.goForward.defaultCombo)))
        XCTAssertEqual(harness.controller.listScreen, .shortcuts)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.openSettings.defaultCombo)))
        XCTAssertEqual(harness.controller.listScreen, .settings)
    }

    func testFindInPageOverlayBlocksLowerLayersAndExpandCollapseAllWorkByKeyboard() throws {
        let harness = try AppKeyboardHarness()
        defer { harness.tearDown() }

        let pageId = newId()
        let parent = newId()
        let child = newId()
        _ = try harness.graph.applyOps(ops: [
            .createPage(id: pageId, title: "Design", journalDay: nil, documentMode: false),
            .insertBlock(id: parent, pageId: pageId, parentId: nil, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Parent note"),
            .insertBlock(id: child, pageId: pageId, parentId: parent, orderKey: try orderKeyBetween(lower: nil, upper: nil), content: "Child note"),
        ], meta: setupMeta)
        harness.controller.selectPage(pageId)
        harness.pump()

        XCTAssertEqual(harness.controller.rows.count, 2)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.findInPage.defaultCombo)))
        XCTAssertTrue(harness.controller.find.isOpen)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 1)

        XCTAssertFalse(harness.press(try XCTUnwrap(AppAction.openAllPages.defaultCombo)))
        XCTAssertNil(harness.controller.listScreen)

        XCTAssertTrue(harness.press(.escape, editing: true))
        XCTAssertFalse(harness.controller.find.isOpen)
        XCTAssertEqual(harness.keyRouter.registrationCount(in: .overlay), 0)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.collapseAll.defaultCombo)))
        XCTAssertEqual(harness.controller.rows.count, 1)

        XCTAssertTrue(harness.press(try XCTUnwrap(AppAction.expandAll.defaultCombo)))
        XCTAssertEqual(harness.controller.rows.count, 2)
    }

    func testWindowShortcutsAndIMESafetyInRealWindow() throws {
        let harness = try AppKeyboardHarness()
        defer { harness.tearDown() }

        let toggleSidebar = try XCTUnwrap(AppAction.toggleSidebar.defaultCombo)
        XCTAssertTrue(harness.state.showSidebar)
        XCTAssertTrue(harness.press(toggleSidebar))
        XCTAssertFalse(harness.state.showSidebar)
        XCTAssertTrue(harness.press(toggleSidebar))
        XCTAssertTrue(harness.state.showSidebar)

        XCTAssertFalse(harness.press(try XCTUnwrap(AppAction.openPalette.defaultCombo), editing: true, ime: true))
        XCTAssertFalse(harness.state.showSearch)
    }
}
