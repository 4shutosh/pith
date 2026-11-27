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
    case bold
    case italic
    case strike
    case highlight
    case externalLink(url: String)
    case link(pageId: String?, deleted: Bool)
    case tag(pageId: String?, deleted: Bool)
    case blockRef(blockId: String)
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
    public static func editable(_ row: FfiFlatBlockRow) -> EditableBlock {
        let prefix = row.display.prefix
        let content = row.renderedContent
        let text = content.hasPrefix(prefix) ? String(content.dropFirst(prefix.count)) : content
        return EditableBlock(status: row.display.taskState.flatMap(TaskStatus.init(state:)), prefix: prefix, text: text)
    }

    public static func combine(prefix: String, body: String) -> String {
        guard !prefix.isEmpty else { return body }
        guard !body.isEmpty else { return prefix }
        if prefix.last?.isWhitespace == true || body.first?.isWhitespace == true {
            return prefix + body
        }
        return prefix + " " + body
    }

    public static func runs(_ display: FfiBlockDisplay) -> (status: TaskStatus?, runs: [DisplayRun]) {
        let runs = display.runs.map { DisplayRun(display: $0.display, source: $0.source, style: RunStyle($0.style)) }
        return (display.taskState.flatMap(TaskStatus.init(state:)), runs)
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
}

extension RunStyle {
    init(_ style: FfiRunStyle) {
        switch style {
        case .plain: self = .plain
        case .marker: self = .bracket
        case .code: self = .code
        case .bold: self = .bold
        case .italic: self = .italic
        case .strike: self = .strike
        case .highlight: self = .highlight
        case let .externalLink(url): self = .externalLink(url: url)
        case let .link(pageId, deleted): self = .link(pageId: pageId, deleted: deleted)
        case let .tag(pageId, deleted): self = .tag(pageId: pageId, deleted: deleted)
        case let .blockRef(blockId): self = .blockRef(blockId: blockId)
        }
    }
}
