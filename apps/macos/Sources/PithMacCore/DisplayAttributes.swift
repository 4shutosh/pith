import AppKit
import PithCore

public extension NSAttributedString.Key {
    static let pithPageId = NSAttributedString.Key("pithPageId")
    static let pithDeletedPageTitle = NSAttributedString.Key("pithDeletedPageTitle")
    static let pithBlockRefId = NSAttributedString.Key("pithBlockRefId")
    static let pithExternalURL = NSAttributedString.Key("pithExternalURL")
}

public enum BlockStyle {
    public static let fontSize: CGFloat = 15
    public static let lineHeight: CGFloat = 24
    public static let fallbackWidth: CGFloat = EditorLayout.maximumContentWidth

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

    static let boldFont: NSFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

    static let italicFont: NSFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

    static func attributes(for kind: FfiHighlightKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .bracket: return [.foregroundColor: Theme.nsBracket]
        case .link: return [.foregroundColor: Theme.nsLink]
        case .tag: return [.foregroundColor: Theme.nsTag]
        case .code: return codeAttributes
        case .blockRef: return blockRefAttributes
        case .bold: return boldAttributes
        case .italic: return italicAttributes
        case .strike: return strikeAttributes
        case .highlight: return highlightAttributes
        case .externalLink: return externalLinkAttributes
        }
    }

    static let boldAttributes: [NSAttributedString.Key: Any] = [
        .font: boldFont,
        .foregroundColor: Theme.nsTextStrong,
    ]

    static let italicAttributes: [NSAttributedString.Key: Any] = [
        .font: italicFont,
    ]

    static let strikeAttributes: [NSAttributedString.Key: Any] = [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: Theme.nsClosedStrike,
        .foregroundColor: Theme.nsTextSecondary,
    ]

    static let highlightAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: Theme.nsSelection,
        .foregroundColor: Theme.nsTextStrong,
    ]

    static let externalLinkAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: Theme.nsLink,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: Theme.nsLink.withAlphaComponent(0.45),
    ]

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

    static let h1Font: NSFont = NSFontManager.shared.convert(Typography.nsSans(TypeScale.sectionTitle), toHaveTrait: .boldFontMask)
    static let h2Font: NSFont = NSFontManager.shared.convert(Typography.nsSans(TypeScale.searchInput), toHaveTrait: .boldFontMask)
    static let h3Font: NSFont = NSFontManager.shared.convert(Typography.nsSans(TypeScale.block), toHaveTrait: .boldFontMask)

    static let h1Paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 30
        style.maximumLineHeight = 30
        return style
    }()

    static let h2Paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 26
        style.maximumLineHeight = 26
        return style
    }()

    public static func baseAttributes(for kind: FfiBlockKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case let .heading(level):
            switch level {
            case 1:
                return [
                    .font: h1Font,
                    .foregroundColor: Theme.nsTextStrong,
                    .paragraphStyle: h1Paragraph,
                    .kern: -0.3,
                ]
            case 2:
                return [
                    .font: h2Font,
                    .foregroundColor: Theme.nsTextStrong,
                    .paragraphStyle: h2Paragraph,
                    .kern: -0.2,
                ]
            default:
                return [
                    .font: h3Font,
                    .foregroundColor: Theme.nsTextStrong,
                    .paragraphStyle: paragraph,
                    .baselineOffset: baselineOffset,
                ]
            }
        case .quote:
            return [
                .font: font,
                .foregroundColor: Theme.nsTextSecondary,
                .paragraphStyle: paragraph,
                .baselineOffset: baselineOffset,
            ]
        case .paragraph, .codeBlock, .divider:
            return editingAttributes
        }
    }

    public static func display(
        _ runs: [DisplayRun],
        closed: Bool,
        kind: FfiBlockKind = .paragraph,
        findMatches: [FfiPageMatch] = [],
        activeFindOrdinal: Int? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = baseAttributes(for: kind)
        let isHeading: Bool = if case .heading = kind { true } else { false }
        for run in runs {
            var attributes = base
            switch run.style {
            case .plain:
                break
            case .code:
                attributes.merge(codeAttributes) { $1 }
            case .bracket:
                attributes.merge(BlockStyle.attributes(for: .bracket)) { $1 }
            case .bold:
                if !isHeading {
                    attributes.merge(boldAttributes) { $1 }
                }
            case .italic:
                if !isHeading {
                    attributes.merge(italicAttributes) { $1 }
                }
            case .strike:
                attributes.merge(strikeAttributes) { $1 }
            case .highlight:
                attributes.merge(highlightAttributes) { $1 }
            case let .externalLink(url):
                attributes.merge(externalLinkAttributes) { $1 }
                attributes[.pithExternalURL] = url
            case let .link(pageId, deleted):
                if deleted {
                    attributes[.foregroundColor] = Theme.nsClosedText
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = Theme.nsClosedStrike
                    if let pageId {
                        attributes[.pithPageId] = pageId
                        attributes[.pithDeletedPageTitle] = run.display
                    }
                } else {
                    attributes[.foregroundColor] = Theme.nsLink
                    attributes[.pithPageId] = pageId
                }
            case let .tag(pageId, deleted):
                if deleted {
                    attributes[.foregroundColor] = Theme.nsClosedText
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = Theme.nsClosedStrike
                    if let pageId {
                        attributes[.pithPageId] = pageId
                        attributes[.pithDeletedPageTitle] = run.display
                    }
                } else {
                    attributes[.foregroundColor] = Theme.nsTag
                    attributes[.pithPageId] = pageId
                }
            case let .blockRef(blockId):
                attributes.merge(blockRefAttributes) { $1 }
                attributes[.pithBlockRefId] = blockId
            }
            if closed {
                attributes[.foregroundColor] = Theme.nsClosedText
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = Theme.nsClosedStrike
            }
            result.append(NSAttributedString(string: run.display, attributes: attributes))
        }
        let shown = result.string
        for (ordinal, match) in findMatches.enumerated() {
            let start = TextOffsets.utf16(fromScalar: Int(match.start), in: shown)
            let end = TextOffsets.utf16(fromScalar: Int(match.start + match.len), in: shown)
            guard end > start, end <= (shown as NSString).length else { continue }
            let range = NSRange(location: start, length: end - start)
            let isActive = activeFindOrdinal == ordinal
            result.addAttribute(
                .backgroundColor,
                value: isActive ? Theme.nsAccent.withAlphaComponent(0.45) : Theme.nsSelection,
                range: range
            )
            if isActive {
                result.addAttribute(.foregroundColor, value: Theme.nsTextStrong, range: range)
            }
        }
        return result
    }
}
