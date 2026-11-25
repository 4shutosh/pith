import Foundation
import PithCore

@MainActor
public final class OutlinerController: ObservableObject {
    @Published public var pages: [FfiPage] = []
    @Published public var selectedPageId: String?
    @Published public var pendingJournalTitle: String?
    @Published public var rows: [FfiFlatBlockRow] = []
    @Published public var totalVisible: UInt64 = 0
    @Published public var backlinks: [FfiBacklink] = []
    @Published public var focusedBlockId: String?
    public var draftText: String = ""
    @Published public var requestedCursorOffset: Int?
    @Published public var cursorRequestSeq: UInt64 = 0
    @Published public var searchQuery: String = ""
    @Published public var searchHits: [FfiSearchHit] = []
    @Published public var isShowingAllPages: Bool = false
    @Published public var errorMessage: String?

    public let graph: PithGraph
    public let actor: String
    public let todayTitle: String
    public var debounceNanoseconds: UInt64 = 300_000_000
    public var pageWindowLimit: UInt64 = 500

    private var draftBaseVersion: Int64 = 0
    private var draftBaseText: String = ""
    private var editPrefix: String = ""
    private var undoGroup: String = newId()
    private var lastDataVersion: Int64 = 0
    private var isComposingIME: Bool = false
    private var debounceTask: Task<Void, Never>?

    public init(graph: PithGraph, actor: String = "me") throws {
        self.graph = graph
        self.actor = actor
        self.todayTitle = try journalTitle(date: nil)
        self.lastDataVersion = try graph.dataVersion()
        try showTodayJournal()
    }

    public var pageTitle: String? {
        if let id = selectedPageId {
            return pages.first(where: { $0.id == id })?.title
        }
        return pendingJournalTitle
    }

    public var isShowingToday: Bool {
        !isShowingAllPages && pageTitle == todayTitle
    }

    public var recentPages: [FfiPage] {
        Self.recent(pages, limit: 8)
    }

    public static func recent(_ pages: [FfiPage], limit: Int) -> [FfiPage] {
        Array(
            pages
                .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }
                .prefix(limit)
        )
    }

    public func reload() {
        do {
            pages = try graph.listPages()
            guard let pageId = selectedPageId else {
                rows = []
                totalVisible = 0
                backlinks = []
                endEditing()
                errorMessage = nil
                return
            }
            let window = try graph.readPageWindow(pageId: pageId, offset: 0, limit: pageWindowLimit)
            rows = window.rows
            totalVisible = window.totalVisible
            backlinks = try graph.backlinks(targetId: pageId)
            if let focused = focusedBlockId, !rows.contains(where: { $0.id == focused }) {
                endEditing()
            }
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func selectPage(_ pageId: String) {
        leaveBlock()
        isShowingAllPages = false
        pendingJournalTitle = nil
        selectedPageId = pageId
        reload()
    }

    public func openTodayJournal() {
        leaveBlock()
        isShowingAllPages = false
        do {
            try showTodayJournal()
        } catch {
            report(error)
        }
    }

    public func showAllPages() {
        leaveBlock()
        isShowingAllPages = true
        run { pages = try graph.listPages() }
    }

    public func openPage(id: String) {
        selectPage(id)
    }

    public func openPageByTitle(_ title: String) {
        leaveBlock()
        do {
            if let existing = try graph.getPageByTitle(title: title) {
                selectPage(existing.id)
                return
            }
            let id = newId()
            _ = try graph.applyOps(
                ops: [.createPage(id: id, title: title, journalDay: nil, documentMode: false)],
                meta: meta("create page \(title)")
            )
            selectPage(id)
        } catch {
            report(error)
        }
    }

    public func focusBlock(_ blockId: String, cursorOffset: Int? = nil) {
        if focusedBlockId != blockId {
            leaveBlock()
            guard let row = rows.first(where: { $0.id == blockId }) else { return }
            beginEditing(row)
        }
        requestCursor(cursorOffset ?? TextOffsets.length(draftText))
    }

    public func blurFocus() {
        leaveBlock()
    }

    public func ensureFirstBlockAndFocus() {
        if let first = rows.first {
            focusBlock(first.id, cursorOffset: TextOffsets.length(BlockPresentation.editable(first.spans).text))
            return
        }
        run {
            let outcome: FfiEditOutcome
            if let pageId = selectedPageId {
                outcome = try graph.appendBlock(pageId: pageId, text: "", meta: meta("new block"))
            } else {
                outcome = try graph.startJournal(date: nil, meta: meta("start journal"))
                selectedPageId = try graph.journalPage(date: nil)?.id
                pendingJournalTitle = nil
            }
            apply(outcome)
        }
    }

    public func updateDraft(blockId: String, text: String, isComposing: Bool) {
        guard focusedBlockId == blockId else { return }
        draftText = text
        isComposingIME = isComposing
        debounceTask?.cancel()
        guard !isComposing else { return }
        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }

    public func flushDraft() {
        debounceTask?.cancel()
        debounceTask = nil
        guard !isComposingIME, let blockId = focusedBlockId, isDirty else { return }
        do {
            let result = try graph.applyOps(
                ops: [.updateBlock(id: blockId, content: editPrefix + draftText, expectedVersion: draftBaseVersion)],
                meta: meta("edit block", group: undoGroup)
            )
            if result.pagesChanged {
                reload()
            } else {
                try refreshRow(blockId)
            }
            if let saved = rows.first(where: { $0.id == blockId }) {
                rebase(on: saved)
            }
        } catch {
            report(error)
        }
    }

    public func handleReturn(at cursorOffset: Int) {
        guard let blockId = focusedBlockId else { return }
        cancelPendingSave()
        let (before, after) = TextOffsets.split(draftText, atScalar: cursorOffset)
        command {
            try graph.splitBlock(
                blockId: blockId,
                baseVersion: draftBaseVersion,
                before: editPrefix + before,
                after: after,
                meta: meta("split block")
            )
        }
    }

    public func handleBackspaceAtStart() {
        guard let blockId = focusedBlockId else { return }
        cancelPendingSave()
        let text = draftText
        command {
            try graph.mergeIntoPrevious(
                blockId: blockId,
                baseVersion: draftBaseVersion,
                text: text,
                meta: meta("merge block")
            )
        }
    }

    public func indentFocusedBlock() {
        guard let blockId = focusedBlockId else { return }
        flushDraft()
        command {
            try graph.indentBlock(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("indent block"))
        }
    }

    public func outdentFocusedBlock() {
        guard let blockId = focusedBlockId else { return }
        flushDraft()
        command {
            try graph.outdentBlock(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("outdent block"))
        }
    }

    public func moveFocusUp(column: Int) {
        guard let blockId = focusedBlockId,
              let idx = rows.firstIndex(where: { $0.id == blockId }),
              idx > 0 else {
            return
        }
        let target = rows[idx - 1]
        let text = BlockPresentation.editable(target.spans).text
        focusBlock(target.id, cursorOffset: TextOffsets.offsetInLastLine(atColumn: column, in: text))
    }

    public func moveFocusDown(column: Int) {
        guard let blockId = focusedBlockId,
              let idx = rows.firstIndex(where: { $0.id == blockId }),
              idx + 1 < rows.count else {
            return
        }
        let target = rows[idx + 1]
        let text = BlockPresentation.editable(target.spans).text
        focusBlock(target.id, cursorOffset: TextOffsets.offsetInFirstLine(atColumn: column, in: text))
    }

    public func cycleTask(caret: Int) {
        guard let blockId = focusedBlockId else { return }
        flushDraft()
        let caretFromEnd = TextOffsets.length(draftText) - caret
        run {
            _ = try graph.cycleTask(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("cycle task"))
            refreshFocused(caretFromEnd: caretFromEnd)
        }
    }

    public func toggleTaskDone(_ blockId: String) {
        if focusedBlockId == blockId {
            flushDraft()
        }
        guard let row = rows.first(where: { $0.id == blockId }) else { return }
        let baseVersion = focusedBlockId == blockId ? draftBaseVersion : row.version
        let caretFromEnd = focusedBlockId == blockId ? 0 : nil as Int?
        run {
            _ = try graph.toggleTaskDone(blockId: blockId, baseVersion: baseVersion, meta: meta("toggle task"))
            if let caretFromEnd {
                refreshFocused(caretFromEnd: caretFromEnd)
            } else {
                reload()
            }
        }
    }

    public func toggleCollapse(_ blockId: String) {
        leaveBlock()
        guard let row = rows.first(where: { $0.id == blockId }) else { return }
        run {
            _ = try graph.applyOps(
                ops: [.setCollapsed(id: row.id, collapsed: !row.collapsed)],
                meta: meta("toggle collapse")
            )
            reload()
        }
    }

    public func undo() {
        flushDraft()
        run {
            _ = try graph.undoLast(actor: actor, force: false)
            afterHistoryStep()
        }
    }

    public func redo() {
        flushDraft()
        run {
            _ = try graph.redoLast(actor: actor, force: false)
            afterHistoryStep()
        }
    }

    public func runSearch(_ query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }
        run { searchHits = try graph.search(query: trimmed, limit: 100) }
    }

    public func openSearchHit(_ hit: FfiSearchHit) {
        switch hit {
        case let .page(pageId, _, _):
            selectPage(pageId)
        case let .block(blockId, pageId, _, _, _, cursor, _):
            selectPage(pageId)
            guard let row = rows.first(where: { $0.id == blockId }) else { return }
            focusBlock(blockId, cursorOffset: editOffset(fromRendered: Int(cursor), in: row))
        }
    }

    public func pollExternalChanges() {
        do {
            let currentVersion = try graph.dataVersion()
            guard currentVersion != lastDataVersion else { return }
            lastDataVersion = currentVersion
            if selectedPageId == nil {
                selectedPageId = try graph.journalPage(date: nil)?.id
                if selectedPageId != nil {
                    pendingJournalTitle = nil
                }
            }
            reload()
            adoptExternalEditOfFocusedBlock()
        } catch {
            report(error)
        }
    }

    private var isDirty: Bool {
        focusedBlockId != nil && draftText != draftBaseText
    }

    private func showTodayJournal() throws {
        if let journal = try graph.journalPage(date: nil) {
            pendingJournalTitle = nil
            selectedPageId = journal.id
        } else {
            selectedPageId = nil
            pendingJournalTitle = try journalTitle(date: nil)
        }
        reload()
    }

    private func beginEditing(_ row: FfiFlatBlockRow) {
        focusedBlockId = row.id
        rebase(on: row)
        draftText = draftBaseText
        undoGroup = newId()
    }

    private func endEditing() {
        cancelPendingSave()
        focusedBlockId = nil
        draftText = ""
    }

    private func leaveBlock() {
        flushDraft()
        endEditing()
    }

    private func cancelPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
        isComposingIME = false
    }

    private func command(_ body: () throws -> FfiEditOutcome?) {
        run {
            guard let outcome = try body() else { return }
            apply(outcome)
        }
    }

    private func apply(_ outcome: FfiEditOutcome) {
        reload()
        guard let row = rows.first(where: { $0.id == outcome.focusBlockId }) else { return }
        let cursor = outcome.cursor.map { editOffset(fromRendered: Int($0), in: row) }
        if focusedBlockId == row.id {
            rebase(on: row)
            undoGroup = newId()
            draftText = draftBaseText
        } else {
            beginEditing(row)
        }
        requestCursor(cursor ?? TextOffsets.length(draftText))
    }

    private func afterHistoryStep() {
        reload()
        if let focused = focusedBlockId, let row = rows.first(where: { $0.id == focused }) {
            beginEditing(row)
            requestCursor(TextOffsets.length(draftText))
        }
    }

    private func adoptExternalEditOfFocusedBlock() {
        guard !isDirty,
              let blockId = focusedBlockId,
              let row = rows.first(where: { $0.id == blockId }),
              row.version != draftBaseVersion else { return }
        rebase(on: row)
        draftText = draftBaseText
        requestCursor(TextOffsets.length(draftText))
    }

    private func refreshRow(_ blockId: String) throws {
        guard let index = rows.firstIndex(where: { $0.id == blockId }) else { return }
        if let row = try graph.blockRow(blockId: blockId) {
            rows[index] = row
        } else {
            reload()
        }
    }

    private func refreshFocused(caretFromEnd: Int) {
        reload()
        guard let blockId = focusedBlockId, let row = rows.first(where: { $0.id == blockId }) else { return }
        rebase(on: row)
        draftText = draftBaseText
        requestCursor(max(0, TextOffsets.length(draftText) - caretFromEnd))
    }

    private func rebase(on row: FfiFlatBlockRow) {
        let editable = BlockPresentation.editable(row.spans)
        draftBaseVersion = row.version
        draftBaseText = editable.text
        editPrefix = editable.prefix
    }

    private func editOffset(fromRendered offset: Int, in row: FfiFlatBlockRow) -> Int {
        max(0, offset - TextOffsets.length(BlockPresentation.editable(row.spans).prefix))
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if case let FfiError.Core(_, message) = error {
            errorMessage = message
        } else {
            errorMessage = "\(error)"
        }
    }

    private func meta(_ summary: String, group: String? = nil) -> FfiTxMeta {
        FfiTxMeta(writer: .user, actor: actor, session: nil, summary: summary, undoGroup: group)
    }

    private func requestCursor(_ offset: Int) {
        requestedCursorOffset = offset
        cursorRequestSeq &+= 1
    }
}
