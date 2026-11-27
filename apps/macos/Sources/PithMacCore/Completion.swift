import PithCore

public struct CompletionItem: Equatable {
    public let label: String
    public let detail: String?
    public let value: String
    public let isNew: Bool
    public let slash: FfiSlashCommand?

    public init(label: String, detail: String?, value: String, isNew: Bool, slash: FfiSlashCommand? = nil) {
        self.label = label
        self.detail = detail
        self.value = value
        self.isNew = isNew
        self.slash = slash
    }
}

public struct CompletionState: Equatable {
    public let context: FfiCompletionContext
    public let items: [CompletionItem]
    public var selected: Int

    public init(context: FfiCompletionContext, items: [CompletionItem], selected: Int) {
        self.context = context
        self.items = items
        self.selected = selected
    }
}

struct BlockCompletionJob {
    let context: FfiCompletionContext
    let editing: String?
    let ticket: UInt64
}
