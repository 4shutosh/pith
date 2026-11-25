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
                part.backgroundColor = Color(red: 1.0, green: 0.95, blue: 0.6)
                part.foregroundColor = .black
            }
            result.append(part)
        }
        return result
    }

    public static func offersCreatePage(query: String, hits: [FfiSearchHit]) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return !hits.contains { hit in
            if case let .page(_, title, _) = hit {
                return title.caseInsensitiveCompare(wanted) == .orderedSame
            }
            return false
        }
    }
}
