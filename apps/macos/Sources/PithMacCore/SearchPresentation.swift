import Foundation
import PithCore
import SwiftUI

public enum SearchPresentation {
    public static func breadcrumb(_ parts: [String]) -> String {
        guard parts.count > 3 else { return parts.joined(separator: " / ") }
        return [parts[0], "…", parts[parts.count - 1]].joined(separator: " / ")
    }

    public static func highlighted(_ segments: [FfiSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if segment.highlighted {
                part.backgroundColor = Theme.accent.opacity(0.24)
                part.foregroundColor = Theme.textStrong
            }
            result.append(part)
        }
        return result
    }

    public static func pageAccessory(isJournal: Bool, backlinks: UInt32?) -> String? {
        if isJournal { return "Journal" }
        switch backlinks ?? 0 {
        case 0: return nil
        case 1: return "1 link"
        case let count: return "\(count) links"
        }
    }

    public static func displayTitle(_ title: String, isJournal: Bool, format: JournalDateFormat) -> String {
        isJournal ? format.format(title) : title
    }

    public static func crumbs(of block: PaletteBlock, format: JournalDateFormat) -> String {
        var parts = block.crumbs
        if let first = parts.first {
            parts[0] = displayTitle(first, isJournal: block.pageIsJournal, format: format)
        }
        return breadcrumb(parts)
    }

    public static func kindLabel(_ kind: PaletteRowKind) -> String {
        switch kind {
        case let .page(page): return page.isJournal ? "Journal" : "Page"
        case .block: return "Block"
        case .command: return "Command"
        case .more: return "More matches"
        case .create: return "New page"
        }
    }

    public static func previewTitle(_ kind: PaletteRowKind, format: JournalDateFormat) -> String {
        switch kind {
        case let .page(page): return displayTitle(page.title, isJournal: page.isJournal, format: format)
        case let .block(block): return displayTitle(block.pageTitle, isJournal: block.pageIsJournal, format: format)
        case let .command(item): return item.title
        case let .more(_, pageTitle, hidden): return displayTitle(pageTitle, isJournal: hidden.first?.pageIsJournal ?? false, format: format)
        case let .create(title): return title
        }
    }

    public static func previewMeta(_ kind: PaletteRowKind, preview: PalettePreview?) -> String? {
        switch (kind, preview) {
        case let (.page, .page(page)?):
            return PreviewWording.subtitle(page)
        case let (.block, .block(context)?):
            return context.crumbs.isEmpty ? nil : context.crumbs.joined(separator: " › ")
        case let (.command(item), _):
            return item.action.category.title
        case let (.more(_, _, hidden), _):
            return hidden.count == 1 ? "1 more matching block" : "\(hidden.count) more matching blocks"
        default:
            return nil
        }
    }
}
