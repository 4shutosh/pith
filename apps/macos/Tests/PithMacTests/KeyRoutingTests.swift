import AppKit
import PithMacCore
import XCTest

@MainActor
final class KeyRoutingTests: XCTestCase {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    }

    func testAPlainWindowReceivesContentShortcuts() {
        XCTAssertTrue(window().receivesContentShortcuts)
    }

    func testPanelsDoNot() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertFalse(panel.receivesContentShortcuts)
    }

    func testNeitherAWindowWithASheetNorTheSheetItself() {
        let main = window()
        let sheet = window()
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertFalse(main.receivesContentShortcuts)
        XCTAssertFalse(sheet.receivesContentShortcuts)
    }

    func testHigherLayerReceivesKeyStrokeBeforeLowerLayer() {
        let router = KeyRouter()
        var trace: [String] = []

        router.register(layer: .screen) { _ in
            trace.append("screen")
            return true
        }
        let overlayId = router.register(layer: .overlay) { _ in
            trace.append("overlay")
            return true
        }

        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 53)))
        XCTAssertEqual(trace, ["overlay"])

        router.unregister(overlayId)
        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 53)))
        XCTAssertEqual(trace, ["overlay", "screen"])
    }

    func testComposingIMEPassesThroughWithoutInvokingAnyHandler() {
        let router = KeyRouter()
        var called = false
        router.register(layer: .overlay) { _ in
            called = true
            return true
        }

        XCTAssertFalse(router.dispatch(KeyStroke(keyCode: 36, isEditingText: true, isComposingIME: true)))
        XCTAssertFalse(called)
    }

    func testActiveOverlayBlocksLowerLayersEvenWhenItDeclinesAKey() {
        let router = KeyRouter()
        var screenCalled = false
        router.register(layer: .screen) { _ in
            screenCalled = true
            return true
        }
        let overlayId = router.register(layer: .overlay) { _ in false }

        XCTAssertFalse(router.dispatch(KeyStroke(keyCode: 44, characters: "/")))
        XCTAssertFalse(screenCalled)

        router.unregister(overlayId)
        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 44, characters: "/")))
        XCTAssertTrue(screenCalled)
    }

    func testPhysicalKeysMapToNamedKeys() {
        XCTAssertEqual(KeyStroke(keyCode: 36).key, .returnKey)
        XCTAssertEqual(KeyStroke(keyCode: 76).key, .returnKey)
        XCTAssertEqual(KeyStroke(keyCode: 53).key, .escape)
        XCTAssertEqual(KeyStroke(keyCode: 126).key, .up)
        XCTAssertEqual(KeyStroke(keyCode: 51).key, .backspace)
        XCTAssertEqual(KeyStroke(keyCode: 117).key, .forwardDelete)
        XCTAssertEqual(KeyStroke(keyCode: 1, characters: "S").key, .character("s"))
        XCTAssertEqual(KeyStroke(keyCode: 105).key, .other(105))
    }

    func testModifiersIgnoreCapsLockAndArrowFlags() {
        XCTAssertEqual(KeyStroke(keyCode: 1, characters: "s", modifiers: [.capsLock]).modifiers, [])
        XCTAssertEqual(KeyStroke(keyCode: 126, modifiers: [.option, .numericPad, .function]).modifiers, [.option])
        XCTAssertEqual(KeyStroke(keyCode: 1, modifiers: [.command, .shift]).modifiers, [.command, .shift])
    }

    func testScopesThatIgnoreTypingAreSkippedWhileEditingText() {
        let router = KeyRouter()
        var trace: [String] = []
        router.register(layer: .screen, whileEditingText: true) { _ in
            trace.append("typing-aware")
            return true
        }
        router.register(layer: .screen) { _ in
            trace.append("selection")
            return true
        }

        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 125, isEditingText: true)))
        XCTAssertEqual(trace, ["typing-aware"])

        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 125)))
        XCTAssertEqual(trace, ["typing-aware", "selection"])
    }

    func testWithinALayerTheNewestScopeGoesFirstAndDeclinedKeysFallThrough() {
        let router = KeyRouter()
        var trace: [String] = []
        router.register(layer: .screen) { _ in
            trace.append("older")
            return true
        }
        router.register(layer: .screen) { stroke in
            trace.append("newer")
            return stroke.key == .escape
        }

        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 53)))
        XCTAssertEqual(trace, ["newer"])
        XCTAssertTrue(router.dispatch(KeyStroke(keyCode: 36)))
        XCTAssertEqual(trace, ["newer", "newer", "older"])
    }
}
