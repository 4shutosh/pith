import AppKit

public extension NSWindow {
    var receivesContentShortcuts: Bool {
        !isSheet && attachedSheet == nil && !(self is NSPanel)
    }
}

public extension NSEvent {
    var isAimedAtMainContent: Bool {
        window?.receivesContentShortcuts ?? false
    }
}

public enum KeyLayer: Int, Comparable {
    case global = 100
    case screen = 200
    case overlay = 300

    public static func < (lhs: KeyLayer, rhs: KeyLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Key: Equatable {
    case returnKey
    case escape
    case up
    case down
    case left
    case right
    case tab
    case backspace
    case forwardDelete
    case pageUp
    case pageDown
    case character(String)
    case other(UInt16)

    public init(keyCode: UInt16, characters: String?) {
        switch keyCode {
        case 36, 76: self = .returnKey
        case 53: self = .escape
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 48: self = .tab
        case 51: self = .backspace
        case 117: self = .forwardDelete
        case 116: self = .pageUp
        case 121: self = .pageDown
        default:
            if let characters, !characters.isEmpty {
                self = .character(characters.lowercased())
            } else {
                self = .other(keyCode)
            }
        }
    }
}

public struct KeyStroke: Equatable {
    public let keyCode: UInt16
    public let characters: String?
    public let modifiers: NSEvent.ModifierFlags
    public let isEditingText: Bool
    public let isComposingIME: Bool

    public init(
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        isEditingText: Bool = false,
        isComposingIME: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        self.isEditingText = isEditingText
        self.isComposingIME = isComposingIME
    }

    public init(event: NSEvent, isEditingText: Bool = false, isComposingIME: Bool = false) {
        self.init(
            keyCode: event.keyCode,
            characters: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            isEditingText: isEditingText,
            isComposingIME: isComposingIME
        )
    }

    public var key: Key {
        Key(keyCode: keyCode, characters: characters)
    }
}

@MainActor
public final class KeyRouter: ObservableObject {
    private struct Entry {
        let id: UUID
        let layer: KeyLayer
        let whileEditingText: Bool
        let isActive: () -> Bool
        let handler: (KeyStroke) -> Bool
    }

    private var entries: [Entry] = []
    private var monitor: Any?

    public init() {}

    @discardableResult
    public func register(
        layer: KeyLayer,
        whileEditingText: Bool = false,
        isActive: @escaping () -> Bool = { true },
        handler: @escaping (KeyStroke) -> Bool
    ) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, layer: layer, whileEditingText: whileEditingText, isActive: isActive, handler: handler))
        return id
    }

    public func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func registrationCount(in layer: KeyLayer) -> Int {
        entries.filter { $0.layer == layer && $0.isActive() }.count
    }

    public func dispatch(_ stroke: KeyStroke) -> Bool {
        guard !stroke.isComposingIME else { return false }
        let activeEntries = entries.enumerated().filter { $0.element.isActive() }
        let hasOverlay = activeEntries.contains { $0.element.layer == .overlay }
        let ordered = activeEntries.sorted { lhs, rhs in
            if lhs.element.layer != rhs.element.layer {
                return lhs.element.layer > rhs.element.layer
            }
            return lhs.offset > rhs.offset
        }
        for (_, entry) in ordered {
            if hasOverlay && entry.layer < .overlay {
                return false
            }
            if stroke.isEditingText && !entry.whileEditingText {
                continue
            }
            if entry.handler(stroke) {
                return true
            }
        }
        return false
    }

    public func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.isAimedAtMainContent else { return event }
            let textView = event.window?.firstResponder as? NSTextView
            let stroke = KeyStroke(
                event: event,
                isEditingText: textView != nil,
                isComposingIME: textView?.hasMarkedText() ?? false
            )
            return self.dispatch(stroke) ? nil : event
        }
    }

    public func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
