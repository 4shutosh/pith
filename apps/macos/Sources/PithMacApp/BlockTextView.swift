import AppKit
import PithCore
import PithMacCore
import SwiftUI

final class PithTextView: NSTextView {
    var onActivate: ((Int) -> Void)?
    var onShiftClick: (() -> Void)?
    var onOpenPage: ((String) -> Void)?
    var onRestoreDeletedPage: ((String, String) -> Void)?
    var onOpenBlockRef: ((String) -> Void)?
    var onHoverPreview: ((HoverPreviewTarget) -> FfiLinkPreview?)?
    var onCommandReturn: ((Int) -> Void)?
    var onMoveBlock: ((Bool, Int) -> Void)?
    var onToggleCollapse: ((Int) -> Void)?
    var onCopyMarkdown: (() -> Void)?
    var onPaste: ((String, Int, Int) -> Bool)?
    var shortcuts: ShortcutStore?

    private var previewTimer: DispatchWorkItem?
    private var previewPopover: NSPopover?
    private var activePreviewTarget: HoverPreviewTarget?

    private var caret: Int {
        TextOffsets.scalar(fromUTF16: selectedRange().location, in: string)
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        let stroke = KeyStroke(event: event, isEditingText: true)
        if let action = shortcuts?.action(matching: stroke, in: .editor) {
            switch action {
            case .cycleTask:
                onCommandReturn?(caret)
            case .moveBlockUp:
                onMoveBlock?(true, caret)
            case .moveBlockDown:
                onMoveBlock?(false, caret)
            case .bold:
                applyInlineFormat(.bold)
            case .italic:
                applyInlineFormat(.italic)
            case .strikethrough:
                applyInlineFormat(.strike)
            case .highlight:
                applyInlineFormat(.highlight)
            case .toggleBlockCollapse:
                onToggleCollapse?(caret)
            case .copyBlockMarkdown:
                onCopyMarkdown?()
            default:
                super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    private func applyInlineFormat(_ format: FfiInlineFormat) {
        let selection = selectedRange()
        let start = TextOffsets.scalar(fromUTF16: selection.location, in: string)
        let end = TextOffsets.scalar(fromUTF16: selection.location + selection.length, in: string)
        let edited = toggleInlineFormat(text: string, start: UInt32(start), end: UInt32(end), format: format)
        textStorage?.setAttributedString(NSAttributedString(string: edited.text, attributes: BlockStyle.editingAttributes))
        let newStart = TextOffsets.utf16(fromScalar: Int(edited.start), in: edited.text)
        let newEnd = TextOffsets.utf16(fromScalar: Int(edited.end), in: edited.text)
        setSelectedRange(NSRange(location: newStart, length: newEnd - newStart))
        didChangeText()
    }

    override func paste(_ sender: Any?) {
        guard isEditable,
              let pasted = NSPasteboard.general.string(forType: .string),
              pasted.contains("\n") else {
            super.paste(sender)
            return
        }
        let selection = selectedRange()
        let start = TextOffsets.scalar(fromUTF16: selection.location, in: string)
        let end = TextOffsets.scalar(fromUTF16: selection.location + selection.length, in: string)
        if onPaste?(pasted, start, end) != true {
            super.paste(sender)
        }
    }

    func caretRectInView() -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let length = (string as NSString).length
        let location = min(selectedRange().location, length)
        let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        if length == 0 || location >= length, !layout.extraLineFragmentRect.isEmpty, string.hasSuffix("\n") || length == 0 {
            rect = layout.extraLineFragmentRect
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(rect.size.width, 1)
        return rect
    }

    override func mouseDown(with event: NSEvent) {
        dismissHoverPreview()
        if event.modifierFlags.contains(.shift), !isEditable {
            onShiftClick?()
            return
        }
        guard !isEditable else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let pageId = pageId(at: point) {
            if let deletedTitle = deletedPageTitle(at: point) {
                onRestoreDeletedPage?(pageId, deletedTitle)
            } else {
                onOpenPage?(pageId)
            }
            return
        }
        if let blockRefId = blockRefId(at: point) {
            onOpenBlockRef?(blockRefId)
            return
        }
        if let rawURL = externalURL(at: point), let url = URL(string: rawURL) {
            NSWorkspace.shared.open(url)
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

    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        applyHoverCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        applyHoverCursor(for: event)
        updateHoverPreview(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        dismissHoverPreview()
    }

    func dismissHoverPreview() {
        previewTimer?.cancel()
        previewTimer = nil
        activePreviewTarget = nil
        previewPopover?.close()
        previewPopover = nil
    }

    private func updateHoverPreview(for event: NSEvent) {
        guard !isEditable, onHoverPreview != nil else {
            dismissHoverPreview()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            dismissHoverPreview()
            return
        }
        let target: HoverPreviewTarget?
        if let pageId = pageId(at: point) {
            target = .page(pageId)
        } else if let blockId = blockRefId(at: point) {
            target = .block(blockId)
        } else {
            target = nil
        }
        guard let target else {
            dismissHoverPreview()
            return
        }
        if target == activePreviewTarget {
            return
        }
        let wasShowing = previewPopover?.isShown == true
        previewTimer?.cancel()
        previewTimer = nil
        activePreviewTarget = target
        let anchorRect = spanBoundingRect(at: point) ?? NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let present: () -> Void = { [weak self] in
            guard let self, !self.isEditable, self.window != nil,
                  self.activePreviewTarget == target,
                  let preview = self.onHoverPreview?(target) else { return }
            if let existing = self.previewPopover, existing.isShown,
               let host = existing.contentViewController as? NSHostingController<HoverPreviewView> {
                host.rootView = HoverPreviewView(preview: preview)
                existing.positioningRect = anchorRect
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: HoverPreviewView(preview: preview))
            popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
            self.previewPopover = popover
        }
        if wasShowing {
            present()
        } else {
            let work = DispatchWorkItem(block: present)
            previewTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
        }
    }

    private func spanBoundingRect(at point: NSPoint) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: containerPoint, in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        let hasAttr = storage.attribute(.pithPageId, at: index, effectiveRange: &effectiveRange) != nil
            || storage.attribute(.pithBlockRefId, at: index, effectiveRange: &effectiveRange) != nil
        guard hasAttr, effectiveRange.length > 0 else { return nil }
        let glyphRange = layout.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private func applyHoverCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if !isEditable, pageId(at: point) != nil || blockRefId(at: point) != nil || externalURL(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func resetCursorRects() {
        if isEditable {
            super.resetCursorRects()
            return
        }
        addCursorRect(bounds, cursor: .iBeam)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.pithPageId, NSAttributedString.Key.pithBlockRefId, NSAttributedString.Key.pithExternalURL] {
            storage.enumerateAttribute(key, in: full) { value, range, _ in
                guard value != nil else { return }
                let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    var shifted = rect
                    shifted.origin.x += self.textContainerOrigin.x
                    shifted.origin.y += self.textContainerOrigin.y
                    self.addCursorRect(shifted, cursor: .pointingHand)
                }
            }
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
        attribute(.pithPageId, at: point) as? String
    }

    private func deletedPageTitle(at point: NSPoint) -> String? {
        attribute(.pithDeletedPageTitle, at: point) as? String
    }

    private func blockRefId(at point: NSPoint) -> String? {
        attribute(.pithBlockRefId, at: point) as? String
    }

    private func externalURL(at point: NSPoint) -> String? {
        attribute(.pithExternalURL, at: point) as? String
    }

    private func attribute(_ key: NSAttributedString.Key, at point: NSPoint) -> Any? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: containerPoint, in: container)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.contains(containerPoint) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(key, at: index, effectiveRange: nil)
    }
}

struct BlockTextView: NSViewRepresentable {
    let blockId: String
    let isEditing: Bool
    var accent: AccentPalette = Theme.currentAccent
    let display: NSAttributedString
    let runs: [DisplayRun]
    @Binding var text: String
    let requestedCursorOffset: Int?
    let cursorRequestSeq: UInt64
    let onActivate: (Int) -> Void
    var onShiftClick: () -> Void = {}
    let onOpenPage: (String) -> Void
    var onRestoreDeletedPage: (String, String) -> Void = { _, _ in }
    var onOpenBlockRef: (String) -> Void = { _ in }
    var onHoverPreview: ((HoverPreviewTarget) -> FfiLinkPreview?)? = nil
    let onTextChange: (String, Bool, Int) -> Void
    var onCaretChange: (Int) -> Void = { _ in }
    let onReturn: (Int) -> Void
    let onCycleTask: (Int) -> Void
    let onBackspaceAtStart: () -> Void
    let onTab: () -> Void
    let onShiftTab: () -> Void
    let onMoveUp: (Int) -> Void
    let onMoveDown: (Int) -> Void
    var onExtendSelectionUp: () -> Void = {}
    var onExtendSelectionDown: () -> Void = {}
    let onEscape: () -> Void
    var completion: CompletionState? = nil
    var onCompletionMove: (Int) -> Void = { _ in }
    var onCompletionAccept: (Int?) -> Void = { _ in }
    var onCompletionDismiss: () -> Void = {}
    var onMoveBlock: (Bool, Int) -> Void = { _, _ in }
    var onToggleCollapse: (Int) -> Void = { _ in }
    var onCopyMarkdown: () -> Void = {}
    var onPaste: (String, Int, Int) -> Bool = { _, _, _ in false }
    var shortcuts: ShortcutStore? = nil

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
        textView.insertionPointColor = Theme.nsCaret
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.nsSelection,
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
        textView.insertionPointColor = Theme.nsCaret
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.nsSelection,
        ]
        textView.onShiftClick = onShiftClick
        textView.onOpenPage = onOpenPage
        textView.onRestoreDeletedPage = onRestoreDeletedPage
        textView.onOpenBlockRef = onOpenBlockRef
        textView.onHoverPreview = onHoverPreview
        textView.onCommandReturn = onCycleTask
        textView.onMoveBlock = onMoveBlock
        textView.onToggleCollapse = onToggleCollapse
        textView.onCopyMarkdown = onCopyMarkdown
        textView.onPaste = onPaste
        textView.shortcuts = shortcuts

        let accentChanged = context.coordinator.lastAccent != accent
        if accentChanged {
            context.coordinator.lastAccent = accent
            textView.needsDisplay = true
        }

        if isEditing {
            textView.dismissHoverPreview()
            let startedEditing = !textView.isEditable
            if startedEditing {
                textView.isEditable = true
                textView.isSelectable = true
                textView.window?.invalidateCursorRects(for: textView)
            }
            if startedEditing || accentChanged || (!textView.hasMarkedText() && textView.string != text) {
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
                    coordinator.updatePopover(textView: textView)
                }
            } else {
                coordinator.updatePopover(textView: textView)
            }
        } else {
            context.coordinator.closePopover()
            if textView.isEditable {
                textView.isEditable = false
                textView.isSelectable = false
                if textView.window?.firstResponder === textView {
                    textView.window?.makeFirstResponder(nil)
                }
                textView.window?.invalidateCursorRects(for: textView)
            }
            if accentChanged || textView.textStorage?.isEqual(to: display) != true {
                textView.textStorage?.setAttributedString(display)
                textView.needsDisplay = true
                textView.window?.invalidateCursorRects(for: textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextView
        var lastAppliedCursorSeq: UInt64 = 0
        var lastAccent: AccentPalette = Theme.currentAccent
        private var popover: NSPopover?
        private var pendingPairCheck = false

        func updatePopover(textView: PithTextView) {
            guard let state = parent.completion else {
                closePopover()
                return
            }
            let list = CompletionList(state: state, onPick: { [weak self] index in self?.parent.onCompletionAccept(index) })
            if let popover, popover.isShown, let host = popover.contentViewController as? NSHostingController<CompletionList> {
                host.rootView = list
                popover.positioningRect = textView.caretRectInView()
                return
            }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = textView.effectiveAppearance
            popover.contentViewController = NSHostingController(rootView: list)
            popover.show(relativeTo: textView.caretRectInView(), of: textView, preferredEdge: .maxY)
            self.popover = popover
            textView.window?.makeFirstResponder(textView)
        }

        func closePopover() {
            popover?.performClose(nil)
            popover = nil
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            pendingPairCheck = replacementString == "[" || replacementString == "("
            return true
        }

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

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView.isEditable,
                  !textView.hasMarkedText() else { return }
            let caret = TextOffsets.scalar(fromUTF16: textView.selectedRange().location, in: textView.string)
            parent.onCaretChange(caret)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, textView.isEditable else { return }
            if pendingPairCheck, !textView.hasMarkedText() {
                pendingPairCheck = false
                let location = textView.selectedRange().location
                let caret = TextOffsets.scalar(fromUTF16: location, in: textView.string)
                if let paired = autoPair(text: textView.string, caret: UInt32(caret)) {
                    textView.textStorage?.setAttributedString(NSAttributedString(string: paired, attributes: BlockStyle.editingAttributes))
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                }
            }
            highlight(textView)
            parent.text = textView.string
            let caret = TextOffsets.scalar(fromUTF16: textView.selectedRange().location, in: textView.string)
            parent.onTextChange(textView.string, textView.hasMarkedText(), caret)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let view = textView as? PithTextView, !view.hasMarkedText() else { return false }
            let caret = TextOffsets.scalar(fromUTF16: view.selectedRange().location, in: view.string)
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []

            if parent.completion != nil {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onCompletionMove(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onCompletionMove(1)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    parent.onCompletionAccept(nil)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCompletionDismiss()
                    return true
                default:
                    break
                }
            }

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
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                guard view.isCaretOnFirstVisualLine() else { return false }
                parent.onExtendSelectionUp()
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                guard view.isCaretOnLastVisualLine() else { return false }
                parent.onExtendSelectionDown()
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
