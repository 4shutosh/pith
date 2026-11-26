import PithCore

public enum TaskStatus: Equatable {
    case todo
    case doing
    case later
    case done
    case canceled

    public init?(state: String) {
        switch state {
        case "TODO": self = .todo
        case "DOING", "NOW": self = .doing
        case "LATER", "WAITING": self = .later
        case "DONE": self = .done
        case "CANCELED", "CANCELLED": self = .canceled
        default: return nil
        }
    }

    public var isClosed: Bool {
        self == .done || self == .canceled
    }
}

public struct EditableBlock: Equatable {
    public let status: TaskStatus?
    public let prefix: String
    public let text: String

    public init(status: TaskStatus?, prefix: String, text: String) {
        self.status = status
        self.prefix = prefix
        self.text = text
    }
}

public enum RunStyle: Equatable {
    case plain
    case code
    case bracket
    case link(pageId: String?)
    case tag(pageId: String?)
    case blockRef
}

public struct DisplayRun: Equatable {
    public let display: String
    public let source: String
    public let style: RunStyle

    public init(display: String, source: String, style: RunStyle) {
        self.display = display
        self.source = source
        self.style = style
    }
}

public enum BlockPresentation {
    public static func editable(_ spans: [FfiSpan]) -> EditableBlock {
        let (status, prefix, rest) = splitTask(spans)
        return EditableBlock(status: status, prefix: prefix, text: rest.map(source).joined())
    }

    public static func combine(prefix: String, body: String) -> String {
        guard !prefix.isEmpty else { return body }
        guard !body.isEmpty else { return prefix }
        if prefix.last?.isWhitespace == true || body.first?.isWhitespace == true {
            return prefix + body
        }
        return prefix + " " + body
    }

    public static func runs(_ spans: [FfiSpan]) -> (status: TaskStatus?, runs: [DisplayRun]) {
        let (status, _, rest) = splitTask(spans)
        return (status, rest.flatMap(displayRuns))
    }

    public static func editUTF16Offset(forDisplayUTF16 index: Int, in runs: [DisplayRun]) -> Int {
        var displayStart = 0
        var editStart = 0
        for run in runs {
            let displayLength = run.display.utf16.count
            let sourceLength = run.source.utf16.count
            if index <= displayStart + displayLength {
                let into = index - displayStart
                if run.display == run.source {
                    return editStart + into
                }
                return into * 2 > displayLength ? editStart + sourceLength : editStart
            }
            displayStart += displayLength
            editStart += sourceLength
        }
        return editStart
    }

    private static func splitTask(_ spans: [FfiSpan]) -> (TaskStatus?, String, [FfiSpan]) {
        guard case let .task(state, taskSource)? = spans.first, let status = TaskStatus(state: state) else {
            return (nil, "", spans)
        }
        var rest = Array(spans.dropFirst())
        var prefix = taskSource
        if case let .text(text)? = rest.first {
            let spaces = text.prefix(while: { $0 == " " || $0 == "\t" })
            prefix += spaces
            let remainder = String(text.dropFirst(spaces.count))
            if remainder.isEmpty {
                rest.removeFirst()
            } else {
                rest[0] = .text(text: remainder)
            }
        }
        return (status, prefix, rest)
    }

    private static func source(_ span: FfiSpan) -> String {
        switch span {
        case let .text(text), let .code(text):
            return text
        case let .task(_, source),
             let .pageLink(_, _, source),
             let .tag(_, _, source),
             let .blockRef(_, _, source):
            return source
        }
    }

    private static func displayRuns(_ span: FfiSpan) -> [DisplayRun] {
        switch span {
        case let .text(text):
            return [DisplayRun(display: text, source: text, style: .plain)]
        case let .code(text):
            return [DisplayRun(display: text, source: text, style: .code)]
        case let .task(_, source):
            return [DisplayRun(display: source, source: source, style: .plain)]
        case let .pageLink(pageId, title, source):
            guard source == "[[\(title)]]" else {
                return [DisplayRun(display: source, source: source, style: .link(pageId: pageId))]
            }
            return [
                DisplayRun(display: "[[", source: "[[", style: .bracket),
                DisplayRun(display: title, source: title, style: .link(pageId: pageId)),
                DisplayRun(display: "]]", source: "]]", style: .bracket),
            ]
        case let .tag(pageId, _, source):
            return [DisplayRun(display: source, source: source, style: .tag(pageId: pageId))]
        case let .blockRef(_, text, source):
            return [DisplayRun(display: text, source: source, style: .blockRef)]
        }
    }
}
