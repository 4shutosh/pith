import Foundation
import PithCore
import SwiftUI

public enum InlineFormatter {
    public static func format(_ spans: [FfiSpan], muted: Bool = false) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            result.append(styled(span, muted: muted))
        }
        return result
    }

    public static func pageId(from url: URL) -> String? {
        guard url.scheme == "pith", url.host == "page" else { return nil }
        return String(url.path.dropFirst())
    }

    private static func styled(_ span: FfiSpan, muted: Bool) -> AttributedString {
        switch span {
        case let .text(text):
            return AttributedString(text)
        case let .code(text):
            var code = AttributedString(text)
            code.font = Typography.mono(13.5)
            code.foregroundColor = Theme.codeText
            code.backgroundColor = Theme.codeBg
            return code
        case let .task(state, _):
            var label = AttributedString(state)
            label.foregroundColor = Theme.textTertiary
            return label
        case let .pageLink(pageId, title, _):
            return link(title, pageId: pageId, color: Theme.link, muted: muted)
        case let .tag(pageId, title, _):
            return link("#\(title)", pageId: pageId, color: Theme.tag, muted: muted)
        case let .blockRef(_, text, _):
            var ref = AttributedString(text)
            ref.underlineStyle = Text.LineStyle(pattern: .dash, color: Theme.bullet)
            return ref
        }
    }

    private static func link(_ display: String, pageId: String?, color: Color, muted: Bool) -> AttributedString {
        var span = AttributedString(display)
        span.foregroundColor = muted ? Theme.textTertiary : color
        if let pageId, let url = URL(string: "pith://page/\(pageId)") {
            span.link = url
        }
        return span
    }
}
