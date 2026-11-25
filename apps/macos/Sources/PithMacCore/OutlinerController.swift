import Foundation
import PithCore

public struct EditConflict: Equatable {
    public let blockId: String
    public let mine: String
    public let theirs: String

    public init(blockId: String, mine: String, theirs: String) {
        self.blockId = blockId
        self.mine = mine
        self.theirs = theirs
    }
}

@MainActor
public final class OutlinerController: ObservableObject {
    @Published public var pages: [FfiPage] = []
    @Published public var selectedPageId: String?
    @Published public var pendingJournalTitle: String?
    @Published public var rows: [FfiFlatBlockRow] = []
    @Published public var totalVisible: UInt64 = 0
    @Published public var backlinks: [FfiBacklink] = []
    @Published public var focusedBlockId: String?
    @Published public var draftText: String = ""
    @Published public var requestedCursorOffset: Int?
    @Published public var cursorRequestSeq: UInt64 = 0
    @Published public var searchQuery: String = ""
    @Published public var searchHits: [FfiSearchHit] = []
    @Published public var conflict: EditConflict?
    @Published public var errorMessage: String?

    public let graph: PithGraph
    public let actor: String
    public var debounceNanoseconds: UInt64 = 300_000_000
    public var pageWindowLimit: UInt64 = 500

    private var draftBaseVersion: Int64 = 0
    private var draftBaseText: String = ""
    private var undoGroup: String = newId()
    private var lastDataVersion: Int64 = 0
    private var isComposingIME: Bool = false
    private var debounceTask: Task<Void, Never>?

    public init(graph: PithGraph, actor: String = "me") throws {
        self.graph = graph
        self.actor = actor
        self.lastDataVersion = try graph.dataVersion()
        try showTodayJournal()
    }

    public var pageTitle: String? {
        if let id = selectedPageId {
            return pages.first(where: { $0.id == id })?.title
        }
        return pendingJournalTitle
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
        guard resolveConflictFirst() else { return }
        leaveBlock()
        pendingJournalTitle = nil
        selectedPageId = pageId
        reload()
    }

    public func openTodayJournal() {
        guard resolveConflictFirst() else { return }
        leaveBlock()
        do {
            try showTodayJournal()
        } catch {
            report(error)
        }
    }

    public func openPage(id: String) {
        selectPage(id)
    }

    public func openPageByTitle(_ title: String) {
        guard resolveConflictFirst() else { return }
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
            guard resolveConflictFirst() else { return }
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
            focusBlock(first.id, cursorOffset: TextOffsets.length(first.renderedContent))
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
        guard !isComposingIME, conflict == nil, let blockId = focusedBlockId, isDirty else { return }
        do {
            _ = try graph.applyOps(
                ops: [.updateBlock(id: blockId, content: draftText, expectedVersion: draftBaseVersion)],
                meta: meta("edit block", group: undoGroup)
            )
            reload()
            if let saved = rows.first(where: { $0.id == blockId }) {
                rebase(on: saved)
            }
        } catch {
            handleWriteError(error, blockId: blockId)
        }
    }

    public func handleReturn(at cursorOffset: Int) {
        guard let blockId = focusedBlockId, conflict == nil else { return }
        cancelPendingSave()
        let (before, after) = TextOffsets.split(draftText, atScalar: cursorOffset)
        command(blockId) {
            try graph.splitBlock(
                blockId: blockId,
                baseVersion: draftBaseVersion,
                before: before,
                after: after,
                meta: meta("split block")
            )
        }
    }

    public func handleBackspaceAtStart() {
        guard let blockId = focusedBlockId, conflict == nil else { return }
        cancelPendingSave()
        let text = draftText
        command(blockId) {
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
        guard conflict == nil else { return }
        command(blockId) {
            try graph.indentBlock(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("indent block"))
        }
    }

    public func outdentFocusedBlock() {
        guard let blockId = focusedBlockId else { return }
        flushDraft()
        guard conflict == nil else { return }
        command(blockId) {
            try graph.outdentBlock(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("outdent block"))
        }
    }

    public func moveFocusUp() {
        guard let blockId = focusedBlockId,
              let idx = rows.firstIndex(where: { $0.id == blockId }),
              idx > 0 else {
            return
        }
        let target = rows[idx - 1]
        focusBlock(target.id, cursorOffset: TextOffsets.length(target.renderedContent))
    }

    public func moveFocusDown() {
        guard let blockId = focusedBlockId,
              let idx = rows.firstIndex(where: { $0.id == blockId }),
              idx + 1 < rows.count else {
            return
        }
        focusBlock(rows[idx + 1].id, cursorOffset: 0)
    }

    public func toggleCollapse(_ blockId: String) {
        guard resolveConflictFirst() else { return }
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
        guard resolveConflictFirst() else { return }
        flushDraft()
        run {
            _ = try graph.undoLast(actor: actor, force: false)
            afterHistoryStep()
        }
    }

    public func redo() {
        guard resolveConflictFirst() else { return }
        flushDraft()
        run {
            _ = try graph.redoLast(actor: actor, force: false)
            afterHistoryStep()
        }
    }

    public func keepMine() {
        guard let current = conflict,
              let row = rows.first(where: { $0.id == current.blockId }) else { return }
        conflict = nil
        rebase(on: row)
        draftText = current.mine
        flushDraft()
    }

    public func keepTheirs() {
        guard let current = conflict,
              let row = rows.first(where: { $0.id == current.blockId }) else { return }
        conflict = nil
        rebase(on: row)
        draftText = row.renderedContent
        requestCursor(TextOffsets.length(draftText))
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
            focusBlock(blockId, cursorOffset: Int(cursor))
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
            detectExternalEditOfFocusedBlock()
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
        draftText = row.renderedContent
        undoGroup = newId()
    }

    private func endEditing() {
        cancelPendingSave()
        focusedBlockId = nil
        draftText = ""
        conflict = nil
    }

    private func leaveBlock() {
        flushDraft()
        if conflict == nil {
            endEditing()
        }
    }

    private func cancelPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
        isComposingIME = false
    }

    private func command(_ blockId: String, _ body: () throws -> FfiEditOutcome?) {
        do {
            guard let outcome = try body() else { return }
            apply(outcome)
        } catch {
            handleWriteError(error, blockId: blockId)
        }
    }

    private func apply(_ outcome: FfiEditOutcome) {
        reload()
        guard let row = rows.first(where: { $0.id == outcome.focusBlockId }) else { return }
        let cursor = outcome.cursor.map(Int.init)
        if focusedBlockId == row.id {
            rebase(on: row)
            undoGroup = newId()
            draftText = row.renderedContent
            requestCursor(cursor ?? TextOffsets.length(draftText))
        } else {
            beginEditing(row)
            requestCursor(cursor ?? TextOffsets.length(draftText))
        }
    }

    private func afterHistoryStep() {
        reload()
        if let focused = focusedBlockId, let row = rows.first(where: { $0.id == focused }) {
            beginEditing(row)
            requestCursor(TextOffsets.length(draftText))
        }
    }

    private func detectExternalEditOfFocusedBlock() {
        guard conflict == nil,
              let blockId = focusedBlockId,
              let row = rows.first(where: { $0.id == blockId }),
              row.version != draftBaseVersion else { return }
        if isDirty {
            conflict = EditConflict(blockId: blockId, mine: draftText, theirs: row.renderedContent)
        } else {
            rebase(on: row)
            draftText = row.renderedContent
            requestCursor(TextOffsets.length(draftText))
        }
    }

    private func resolveConflictFirst() -> Bool {
        guard conflict != nil else { return true }
        errorMessage = "Resolve the edit conflict first: keep your text or use theirs."
        return false
    }

    private func rebase(on row: FfiFlatBlockRow) {
        draftBaseVersion = row.version
        draftBaseText = row.renderedContent
    }

    private func handleWriteError(_ error: Error, blockId: String) {
        if case let FfiError.Core(code, _) = error, code == "version_mismatch" {
            let mine = draftText
            reload()
            if let row = rows.first(where: { $0.id == blockId }) {
                focusedBlockId = blockId
                draftText = mine
                conflict = EditConflict(blockId: blockId, mine: mine, theirs: row.renderedContent)
            }
            return
        }
        report(error)
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
