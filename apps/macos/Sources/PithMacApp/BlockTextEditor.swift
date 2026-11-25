import AppKit
import PithMacCore
import SwiftUI

final class OutlinerNSTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else {
            return super.intrinsicContentSize
        }
        layout.ensureLayout(for: container)
        let rect = layout.usedRect(for: container)
        let minHeight: CGFloat = 22
        return NSSize(width: NSView.noIntrinsicMetric, height: max(minHeight, ceil(rect.height + 4)))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}

struct BlockTextEditor: NSViewRepresentable {
    let blockId: String
    @Binding var text: String
    let requestedCursorOffset: Int?
    let cursorRequestSeq: UInt64
    let onTextChange: (String, Bool) -> Void
    let onReturn: (Int) -> Void
    let onBackspaceAtStart: () -> Void
    let onTab: () -> Void
    let onShiftTab: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> OutlinerNSTextView {
        let textView = OutlinerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.invalidateIntrinsicContentSize()

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.applyCursor(textView: textView)
        }
        return textView
    }

    func updateNSView(_ textView: OutlinerNSTextView, context: Context) {
        context.coordinator.parent = self
        if !textView.hasMarkedText() && textView.string != text {
            let previousSelection = textView.selectedRange()
            textView.string = text
            let maxLoc = (text as NSString).length
            let clamped = min(previousSelection.location, maxLoc)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            textView.invalidateIntrinsicContentSize()
        }

        if context.coordinator.lastAppliedBlockId != blockId
            || context.coordinator.lastAppliedCursorSeq != cursorRequestSeq {
            DispatchQueue.main.async {
                if textView.window?.firstResponder !== textView {
                    textView.window?.makeFirstResponder(textView)
                }
                context.coordinator.applyCursor(textView: textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextEditor
        var lastAppliedBlockId: String = ""
        var lastAppliedCursorSeq: UInt64 = 0

        init(_ parent: BlockTextEditor) {
            self.parent = parent
        }

        func applyCursor(textView: NSTextView) {
            lastAppliedBlockId = parent.blockId
            lastAppliedCursorSeq = parent.cursorRequestSeq
            guard let offset = parent.requestedCursorOffset else { return }
            let utf16Offset = TextOffsets.utf16(fromScalar: offset, in: textView.string)
            textView.setSelectedRange(NSRange(location: utf16Offset, length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            let isComposing = textView.hasMarkedText()
            parent.text = newText
            parent.onTextChange(newText, isComposing)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() {
                return false
            }

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                let charOffset = TextOffsets.scalar(fromUTF16: textView.selectedRange().location, in: textView.string)
                parent.onReturn(charOffset)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                let sel = textView.selectedRange()
                if sel.location == 0 && sel.length == 0 {
                    parent.onBackspaceAtStart()
                    return true
                }
                return false

            case #selector(NSResponder.insertTab(_:)):
                parent.onTab()
                return true

            case #selector(NSResponder.insertBacktab(_:)):
                parent.onShiftTab()
                return true

            case #selector(NSResponder.moveUp(_:)):
                if isOnFirstLine(textView) {
                    parent.onMoveUp()
                    return true
                }
                return false

            case #selector(NSResponder.moveDown(_:)):
                if isOnLastLine(textView) {
                    parent.onMoveDown()
                    return true
                }
                return false

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true

            default:
                return false
            }
        }

        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            let loc = textView.selectedRange().location
            let prefix = (textView.string as NSString).substring(to: min(loc, (textView.string as NSString).length))
            return !prefix.contains("\n")
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let loc = min(textView.selectedRange().location, ns.length)
            let suffix = ns.substring(from: loc)
            return !suffix.contains("\n")
        }
    }
}
