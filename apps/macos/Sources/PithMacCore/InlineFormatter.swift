import Foundation
import PithCore
import SwiftUI

public enum InlineFormatter {
    public static func format(_ spans: [FfiSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            result.append(styled(span))
        }
        return result
    }

    public static func pageId(from url: URL) -> String? {
        guard url.scheme == "pith", url.host == "page" else { return nil }
        return String(url.path.dropFirst())
    }

    private static func styled(_ span: FfiSpan) -> AttributedString {
        switch span {
        case let .text(text):
            return AttributedString(text)
        case let .code(text):
            var code = AttributedString(text)
            code.font = .system(.body, design: .monospaced)
            code.backgroundColor = Color.secondary.opacity(0.14)
            return code
        case let .task(state):
            var badge = AttributedString(state)
            badge.font = .system(.caption, design: .monospaced).bold()
            badge.foregroundColor = state == "DONE" ? .secondary : .orange
            return badge
        case let .pageLink(pageId, title):
            return link(title, pageId: pageId, color: .accentColor)
        case let .tag(pageId, title):
            return link("#\(title)", pageId: pageId, color: .teal)
        case let .blockRef(_, text):
            var ref = AttributedString(text)
            ref.underlineStyle = .single
            ref.foregroundColor = .secondary
            return ref
        }
    }

    private static func link(_ display: String, pageId: String?, color: Color) -> AttributedString {
        var span = AttributedString(display)
        span.foregroundColor = color
        if let pageId, let url = URL(string: "pith://page/\(pageId)") {
            span.link = url
        }
        return span
    }
}
