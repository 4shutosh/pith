import AppKit
import PithCore
import PithMacCore
import SwiftUI

final class PithTextView: NSTextView {
    var onActivate: ((Int) -> Void)?
    var onOpenPage: ((String) -> Void)?
    var onCommandReturn: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isEditable, isReturn, event.modifierFlags.contains(.command), !hasMarkedText() {
            onCommandReturn?(TextOffsets.scalar(fromUTF16: selectedRange().location, in: string))
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditable else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let pageId = pageId(at: point) {
            onOpenPage?(pageId)
            return
        }
        onActivate?(characterIndexForInsertion(at: point))
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(within: rect), color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -2, dy: 0), avoidAdditionalLayout: flag)
    }

    private func caretRect(within rect: NSRect) -> NSRect {
        let height = BlockStyle.glyphHeight
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: 2, height: height)
    }

    override func resetCursorRects() {
        if isEditable {
            super.resetCursorRects()
        } else {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return BlockStyle.lineHeight }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return max(BlockStyle.lineHeight, ceil(layout.usedRect(for: container).height))
    }

    func isCaretOnFirstVisualLine() -> Bool {
        lineRect(forCharacter: selectedRange().location).minY <= lineRect(forCharacter: 0).minY
    }

    func isCaretOnLastVisualLine() -> Bool {
        let length = (string as NSString).length
        return lineRect(forCharacter: selectedRange().location).minY >= lineRect(forCharacter: length).minY
    }

    private func lineRect(forCharacter index: Int) -> NSRect {
        guard let layout = layoutManager else { return .zero }
        let length = (string as NSString).length
        if length == 0 || index >= length {
            return layout.extraLineFragmentRect.isEmpty && length > 0
                ? layout.lineFragmentRect(forGlyphAt: max(0, layout.numberOfGlyphs - 1), effectiveRange: nil)
                : layout.extraLineFragmentRect
        }
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func pageId(at point: NSPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: containerPoint, in: container)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.contains(containerPoint) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.pithPageId, at: index, effectiveRange: nil) as? String
    }
}

struct BlockTextView: NSViewRepresentable {
    let blockId: String
    let isEditing: Bool
    let display: NSAttributedString
    let runs: [DisplayRun]
    @Binding var text: String
    let requestedCursorOffset: Int?
    let cursorRequestSeq: UInt64
    let onActivate: (Int) -> Void
    let onOpenPage: (String) -> Void
    let onTextChange: (String, Bool) -> Void
    let onReturn: (Int) -> Void
    let onCycleTask: (Int) -> Void
    let onBackspaceAtStart: () -> Void
    let onTab: () -> Void
    let onShiftTab: () -> Void
    let onMoveUp: (Int) -> Void
    let onMoveDown: (Int) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PithTextView {
        let textView = PithTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.insertionPointColor = NSColor(hex: 0xF4F4F6)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: 0x5E6AD2).withAlphaComponent(0.55),
            .foregroundColor: NSColor.white,
        ]
        textView.defaultParagraphStyle = BlockStyle.paragraph
        textView.typingAttributes = BlockStyle.editingAttributes
        configure(textView, context: context)
        return textView
    }

    func updateNSView(_ textView: PithTextView, context: Context) {
        context.coordinator.parent = self
        configure(textView, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PithTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width))
    }

    private func configure(_ textView: PithTextView, context: Context) {
        textView.onActivate = { index in
            let editUTF16 = BlockPresentation.editUTF16Offset(forDisplayUTF16: index, in: runs)
            let editText = runs.map(\.source).joined()
            onActivate(TextOffsets.scalar(fromUTF16: editUTF16, in: editText))
        }
        textView.onOpenPage = onOpenPage
        textView.onCommandReturn = onCycleTask

        if isEditing {
            let startedEditing = !textView.isEditable
            if startedEditing {
                textView.isEditable = true
                textView.isSelectable = true
                textView.window?.invalidateCursorRects(for: textView)
            }
            if startedEditing || (!textView.hasMarkedText() && textView.string != text) {
                let previous = textView.selectedRange()
                textView.textStorage?.setAttributedString(
                    NSAttributedString(string: text, attributes: BlockStyle.editingAttributes)
                )
                context.coordinator.highlight(textView)
                let length = (text as NSString).length
                textView.setSelectedRange(NSRange(location: min(previous.location, length), length: 0))
            }
            let coordinator = context.coordinator
            if startedEditing || coordinator.lastAppliedCursorSeq != cursorRequestSeq {
                coordinator.lastAppliedCursorSeq = cursorRequestSeq
                DispatchQueue.main.async {
                    if textView.window?.firstResponder !== textView {
                        textView.window?.makeFirstResponder(textView)
                    }
                    coordinator.applyCursor(textView: textView)
                }
            }
        } else {
            if textView.isEditable {
                textView.isEditable = false
                textView.isSelectable = false
                if textView.window?.firstResponder === textView {
                    textView.window?.makeFirstResponder(nil)
                }
                textView.window?.invalidateCursorRects(for: textView)
            }
            if textView.textStorage?.isEqual(to: display) != true {
                textView.textStorage?.setAttributedString(display)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextView
        var lastAppliedCursorSeq: UInt64 = 0

        init(_ parent: BlockTextView) {
            self.parent = parent
        }

        func applyCursor(textView: NSTextView) {
            guard let offset = parent.requestedCursorOffset else { return }
            let utf16 = TextOffsets.utf16(fromScalar: offset, in: textView.string)
            textView.setSelectedRange(NSRange(location: utf16, length: 0))
        }

        func highlight(_ textView: NSTextView) {
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            BlockStyle.applyHighlights(to: storage, highlights: PithCore.highlight(text: textView.string))
            textView.typingAttributes = BlockStyle.editingAttributes
            textView.setSelectedRange(selection)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, textView.isEditable else { return }
            highlight(textView)
            parent.text = textView.string
            parent.onTextChange(textView.string, textView.hasMarkedText())
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let view = textView as? PithTextView, !view.hasMarkedText() else { return false }
            let caret = TextOffsets.scalar(fromUTF16: view.selectedRange().location, in: view.string)
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if modifiers.contains(.shift) {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onReturn(caret)
                }
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                let selection = view.selectedRange()
                guard selection.location == 0, selection.length == 0 else { return false }
                parent.onBackspaceAtStart()
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onShiftTab()
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard view.isCaretOnFirstVisualLine() else { return false }
                parent.onMoveUp(TextOffsets.column(ofScalar: caret, in: view.string))
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard view.isCaretOnLastVisualLine() else { return false }
                parent.onMoveDown(TextOffsets.column(ofScalar: caret, in: view.string))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
