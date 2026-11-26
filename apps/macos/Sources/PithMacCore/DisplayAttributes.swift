import AppKit
import PithCore

public extension NSAttributedString.Key {
    static let pithPageId = NSAttributedString.Key("pithPageId")
}

public enum BlockStyle {
    public static let fontSize: CGFloat = 15
    public static let lineHeight: CGFloat = 24

    public static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    public static let font: NSFont = {
        Typography.registerBundledFonts()
        return Typography.nsSans(fontSize)
    }()

    public static let glyphHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)

    public static let baselineOffset: CGFloat = ((lineHeight - glyphHeight) / 2).rounded()

    public static let editingAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: Theme.nsTextPrimary,
        .paragraphStyle: paragraph,
        .baselineOffset: baselineOffset,
    ]

    public static func applyHighlights(to storage: NSTextStorage, highlights: [FfiHighlight]) {
        let text = storage.string
        storage.beginEditing()
        storage.setAttributes(editingAttributes, range: NSRange(location: 0, length: storage.length))
        for highlight in highlights {
            let start = TextOffsets.utf16(fromScalar: Int(highlight.start), in: text)
            let end = TextOffsets.utf16(fromScalar: Int(highlight.start + highlight.len), in: text)
            storage.addAttributes(attributes(for: highlight.kind), range: NSRange(location: start, length: end - start))
        }
        storage.endEditing()
    }

    static func attributes(for kind: FfiHighlightKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .bracket: return [.foregroundColor: Theme.nsBracket]
        case .link: return [.foregroundColor: Theme.nsLink]
        case .tag: return [.foregroundColor: Theme.nsTag]
        case .code: return codeAttributes
        case .blockRef: return blockRefAttributes
        }
    }

    static let codeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFontManager.shared.font(withFamily: Typography.monoFamily, traits: [], weight: 5, size: 13.5)
            ?? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
        .foregroundColor: Theme.nsCodeText,
        .backgroundColor: Theme.nsCodeBg,
    ]

    static let blockRefAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue,
        .underlineColor: Theme.nsBracket,
    ]

    public static func display(_ runs: [DisplayRun], closed: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = editingAttributes
        for run in runs {
            var attributes = base
            switch run.style {
            case .plain:
                break
            case .code:
                attributes.merge(codeAttributes) { $1 }
            case .bracket:
                attributes.merge(BlockStyle.attributes(for: .bracket)) { $1 }
            case let .link(pageId):
                attributes[.foregroundColor] = Theme.nsLink
                attributes[.pithPageId] = pageId
            case let .tag(pageId):
                attributes[.foregroundColor] = Theme.nsTag
                attributes[.pithPageId] = pageId
            case .blockRef:
                attributes.merge(blockRefAttributes) { $1 }
            }
            if closed {
                attributes[.foregroundColor] = Theme.nsClosedText
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = Theme.nsClosedStrike
            }
            result.append(NSAttributedString(string: run.display, attributes: attributes))
        }
        return result
    }
}
