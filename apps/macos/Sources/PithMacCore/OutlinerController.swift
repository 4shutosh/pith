import Foundation
import os
import PithCore

public enum NavTarget: Equatable {
    case page(id: String, zoomedBlockId: String?)
    case pendingJournal(title: String)
    case allPages
    case shortcuts
    case settings
    case journals

    var pageId: String? {
        if case let .page(id, _) = self { return id }
        return nil
    }
}

public enum ListScreen: Equatable {
    case allPages
    case shortcuts
    case settings
}

public enum SidebarDestination: Equatable {
    case journals
    case allPages
    case shortcuts
    case settings
    case page(String)
}

@MainActor
public final class OutlinerController: ObservableObject {
    @Published public private(set) var library = PageLibrary()
    @Published public var journals: [FfiPage] = []
    @Published public private(set) var renameRequest: UInt64 = 0
    @Published public var pendingPageDelete: FfiPage?
    @Published public var pendingPageRestore: (id: String, title: String)?
    @Published public var unlinkedRefs: [FfiUnlinkedRef] = []
    @Published public private(set) var unlinkedRefsLoaded: Bool = false
    @Published public private(set) var isJournalStream: Bool = false
    @Published public private(set) var journalSections: [JournalSection] = []
    @Published public private(set) var hasOlderJournals: Bool = false
    public var journalStreamDays: Int = 7
    public static let journalStreamStep = 7
    static let libraryPatchLimit = 200
    @Published public var selectedPageId: String?
    @Published public var pendingJournalTitle: String?
    @Published public var rows: [FfiFlatBlockRow] = []
    @Published public var totalVisible: UInt64 = 0
    @Published public private(set) var earlierRowsAnchor: EarlierRowsAnchor?
    @Published public var backlinks: [FfiBacklink] = []
    @Published public var focusedBlockId: String?
    @Published public var selectedBlockIds: Set<String> = []
    public var draftText: String = ""
    @Published public var requestedCursorOffset: Int?
    @Published public var cursorRequestSeq: UInt64 = 0
    @Published public private(set) var listScreen: ListScreen?
    @Published public var zoomedBlockId: String?
    @Published public var breadcrumb: [FfiCrumb] = []
    @Published public var completion: CompletionState?
    @Published public var errorMessage: String?
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false

    public let graph: PithGraph
    public let worker: GraphWorker
    public let background: GraphWorker
    public let shortcuts: ShortcutStore
    public let search = PaletteSearch()
    public let find = FindState()
    public let directory = PageDirectoryModel()
    public let actor: String
    public let todayTitle: String
    public var debounceNanoseconds: UInt64 = 300_000_000
    public var pageWindowLimit: UInt64 = 500

    private var draftBaseVersion: Int64 = 0
    private var draftBaseText: String = ""
    private var editPrefix: String = ""
    private var selectionAnchorId: String?
    private var selectionFocusId: String?
    private var backStack: [NavTarget] = []
    private var forwardStack: [NavTarget] = []
    private var isRestoringHistory: Bool = false
    private var undoGroup: String = newId()
    private var lastDataVersion: Int64 = 0
    private var changeCursor: FfiChangeCursor
    private var completionTicket: UInt64 = 0
    private lazy var summariesFlight: SingleFlight<Void> = SingleFlight { [weak self] _ in
        guard let self else { return }
        do {
            directory.show(try await background.run { try $0.listPageSummaries() })
        } catch {
            report(error)
        }
    }
    private lazy var searchFlight: SingleFlight<String> = SingleFlight { [weak self] query in
        guard let self else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let hits = trimmed.isEmpty ? [] : try await worker.run { try $0.search(query: trimmed, limit: 100) }
            if !searchFlight.hasPending {
                search.show(query, hits: hits)
            }
        } catch {
            report(error)
        }
    }
    private lazy var completionFlight: SingleFlight<BlockCompletionJob> = SingleFlight { [weak self] job in
        guard let self else { return }
        await completeBlockReference(job)
    }
    private var lastEditedBlockId: String?
    private var isComposingIME: Bool = false
    private var isEditingRef: Bool = false
    private var debounceTask: Task<Void, Never>?
    private var windowOffset: UInt64 = 0
    private let signposter = OSSignposter(subsystem: "app.pith", category: "editor")

    public init(
        graph: PithGraph,
        actor: String = "me",
        shortcuts: ShortcutStore? = nil,
        worker: GraphWorker? = nil,
        background: GraphWorker? = nil
    ) throws {
        self.graph = graph
        self.worker = worker ?? GraphWorker(graph: graph)
        self.background = background ?? GraphWorker(graph: graph, qos: .utility)
        self.shortcuts = shortcuts ?? ShortcutStore.shared
        self.actor = actor
        self.todayTitle = try journalTitle(date: nil)
        self.lastDataVersion = try graph.dataVersion()
        self.changeCursor = try graph.changeCursor()
        self.isJournalStream = true
        try showTodayJournal()
    }

    public var currentPage: FfiPage? {
        guard let id = selectedPageId else { return nil }
        return library[id]
    }

    public var pageTitle: String? {
        if let page = currentPage {
            return page.title
        }
        return pendingJournalTitle
    }

    public var isShowingToday: Bool {
        listScreen == nil && pageTitle == todayTitle
    }

    public var isShowingJournal: Bool {
        listScreen == nil && (pendingJournalTitle != nil || currentPage?.journalDay != nil)
    }

    public var currentJournalDate: String? {
        if let pending = pendingJournalTitle { return pending }
        if let page = currentPage, page.journalDay != nil { return page.title }
        return nil
    }

    public var favoritePages: [FfiPage] {
        library.favorites
    }

    public var hasMoreRows: Bool {
        !isJournalStream && windowOffset + UInt64(rows.count) < totalVisible
    }

    public var rowsAbove: UInt64 {
        hasEarlierRows ? windowOffset : 0
    }

    public var rowsBelow: UInt64 {
        hasMoreRows ? totalVisible - windowOffset - UInt64(rows.count) : 0
    }

    public var hasEarlierRows: Bool {
        !isJournalStream && zoomedBlockId == nil && windowOffset > 0
    }

    public var isShowingAllPages: Bool {
        listScreen == .allPages
    }

    public var recentPages: [FfiPage] {
        library.recents
    }

    public var sidebarDestination: SidebarDestination? {
        switch listScreen {
        case .allPages: return .allPages
        case .shortcuts: return .shortcuts
        case .settings: return .settings
        case nil: break
        }
        if isJournalStream && zoomedBlockId == nil {
            return .journals
        }
        if let id = selectedPageId,
           favoritePages.contains(where: { $0.id == id }) || recentPages.contains(where: { $0.id == id }) {
            return .page(id)
        }
        return isShowingJournal ? .journals : nil
    }

    private func loadEverything() {
        do {
            let fresh = try graph.changeCursor()
            try reloadPageLists()
            changeCursor = fresh
        } catch {
            report(error)
        }
        loadView()
    }

    private func loadView() {
        do {
            let changes = try graph.changesAfter(cursor: changeCursor)
            changeCursor = changes.cursor
            if changes.reloadAll {
                try reloadPageLists()
            } else if !changes.pages.isEmpty {
                try refreshLibrary(changes.pages)
                try reloadJournals()
                forgetDeletedPages(changes.pages)
            }
            try resolvePendingJournal()
            try loadVisible()
            try refreshPageExtras(unlinked: true)
            reconcileFocusAndSelection()
            if find.isOpen {
                refreshFindMatches(jumpToActive: false)
            }
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func applyChanges() {
        do {
            let changes = try graph.changesAfter(cursor: changeCursor)
            let plan = RefreshPlan.make(changes, visiblePages: visiblePageIds, loadedRows: Set(rows.map(\.id)))
            changeCursor = changes.cursor
            guard !plan.isEmpty else { return }
            if plan.reloadAll {
                try reloadPageLists()
                forgetDeletedPages(Array(Set(backStack.compactMap(\.pageId) + forwardStack.compactMap(\.pageId))))
                if try leaveDeletedViewIfNeeded() {
                    return
                }
                loadView()
                adoptExternalEditOfFocusedBlock()
                return
            }
            var reloadVisible = plan.reloadVisible
            if plan.reloadPageLists {
                let streamDays = journals.map(\.id)
                try refreshLibrary(changes.pages)
                try reloadJournals()
                forgetDeletedPages(changes.pages)
                if try leaveDeletedViewIfNeeded() {
                    return
                }
                if try resolvePendingJournal() || (isJournalStream && journals.map(\.id) != streamDays) {
                    reloadVisible = true
                }
            }
            if reloadVisible {
                try loadVisible()
            } else if !plan.patchRows.isEmpty {
                try patchRows(plan.patchRows)
            }
            try refreshPageExtras(unlinked: plan.touchesOtherPages)
            if listScreen == .allPages {
                refreshPageSummaries()
            }
            reconcileFocusAndSelection()
            if find.isOpen && (reloadVisible || plan.changesVisibleRows) {
                refreshFindMatches(jumpToActive: false)
            }
            adoptExternalEditOfFocusedBlock()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    private var visiblePageIds: Set<String> {
        var ids = Set(rows.map(\.pageId))
        if let selectedPageId {
            ids.insert(selectedPageId)
        }
        ids.formUnion(journalSections.compactMap(\.pageId))
        return ids
    }

    private func reloadPageLists() throws {
        update(\.library, to: PageLibrary(try graph.listPages()))
        try reloadJournals()
        refreshPageSummaries()
    }

    private func reloadJournals() throws {
        update(\.journals, to: try graph.listJournals(limit: UInt32(max(30, journalStreamDays + 2))))
    }

    private func refreshLibrary(_ changed: [String]) throws {
        guard changed.count <= Self.libraryPatchLimit else {
            update(\.library, to: PageLibrary(try graph.listPages()))
            return
        }
        var upserts: [FfiPage] = []
        var removals: [String] = []
        for id in changed {
            if let page = try graph.getPage(id: id) {
                upserts.append(page)
            } else {
                removals.append(id)
            }
        }
        var next = library
        next.apply(upserts: upserts, removals: removals)
        update(\.library, to: next)
    }

    @discardableResult
    private func resolvePendingJournal() throws -> Bool {
        guard selectedPageId == nil, let pending = pendingJournalTitle,
              let journal = try graph.journalPage(date: pending) else { return false }
        selectedPageId = journal.id
        pendingJournalTitle = nil
        return true
    }

    private func forgetDeletedPages(_ changed: [String]) {
        let gone = Set(changed.filter { library[$0] == nil })
        guard !gone.isEmpty else { return }
        let points = { (target: NavTarget) -> Bool in
            if case let .page(id, _) = target { return gone.contains(id) }
            return false
        }
        backStack.removeAll(where: points)
        forwardStack.removeAll(where: points)
        syncHistoryFlags()
    }

    private func leaveDeletedViewIfNeeded() throws -> Bool {
        guard listScreen == nil, let id = selectedPageId, library[id] == nil else {
            return false
        }
        clearSelection()
        endEditing()
        if isJournalStream && zoomedBlockId == nil {
            selectedPageId = nil
            pendingJournalTitle = todayTitle
            try loadVisible()
            return true
        }
        if let previous = backStack.popLast() {
            syncHistoryFlags()
            navigate(to: previous)
        } else {
            isRestoringHistory = true
            openTodayJournal()
            isRestoringHistory = false
        }
        return true
    }

    private func loadVisible() throws {
        if isJournalStream && zoomedBlockId == nil {
            try loadJournalStream()
            return
        }
        update(\.journalSections, to: [])
        update(\.hasOlderJournals, to: false)
        guard let pageId = selectedPageId else {
            update(\.rows, to: [])
            update(\.totalVisible, to: 0)
            endEditing()
            return
        }
        if let zoomed = zoomedBlockId, try graph.blockRow(blockId: zoomed) == nil {
            zoomedBlockId = nil
        }
        let window: FfiPageWindow
        let limit = max(pageWindowLimit, UInt64(rows.count))
        if let zoomed = zoomedBlockId {
            window = try graph.readBlockWindow(blockId: zoomed, offset: 0, limit: limit)
            update(\.breadcrumb, to: try graph.blockBreadcrumb(blockId: zoomed))
        } else {
            window = try graph.readPageWindow(pageId: pageId, offset: windowOffset, limit: limit)
            update(\.breadcrumb, to: [])
        }
        update(\.rows, to: window.rows)
        update(\.totalVisible, to: window.totalVisible)
    }

    private func patchRows(_ ids: [String]) throws {
        var next = rows
        let fresh = try graph.blockRows(blockIds: ids)
        for row in fresh {
            if let index = next.firstIndex(where: { $0.id == row.id }) {
                next[index] = row
            }
        }
        update(\.rows, to: next)
    }

    private func refreshPageExtras(unlinked: Bool) throws {
        guard listScreen == nil, !isJournalStream || zoomedBlockId != nil, let pageId = selectedPageId else {
            update(\.backlinks, to: [])
            return
        }
        update(\.backlinks, to: try graph.backlinks(targetId: pageId))
        if unlinked && unlinkedRefsLoaded {
            update(\.unlinkedRefs, to: try graph.unlinkedReferences(pageId: pageId, limit: 50))
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<OutlinerController, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    public func loadOlderJournals() {
        guard isJournalStream, hasOlderJournals else { return }
        journalStreamDays += Self.journalStreamStep
        loadView()
    }

    private func loadJournalStream() throws {
        let interval = signposter.beginInterval("journalStream")
        defer { signposter.endInterval("journalStream", interval) }
        var all: [FfiFlatBlockRow] = []
        if let todayId = selectedPageId {
            all = try graph.readPageWindow(pageId: todayId, offset: 0, limit: pageWindowLimit).rows
        }
        var sections = [JournalSection(pageId: selectedPageId, title: pageTitle ?? todayTitle, rowRange: 0..<all.count)]
        let past = journals.filter { $0.id != selectedPageId && $0.title < todayTitle }
        for journal in past.prefix(journalStreamDays) {
            let window = try graph.readPageWindow(pageId: journal.id, offset: 0, limit: pageWindowLimit)
            guard !window.rows.isEmpty else { continue }
            let start = all.count
            all.append(contentsOf: window.rows)
            sections.append(JournalSection(pageId: journal.id, title: journal.title, rowRange: start..<all.count))
        }
        update(\.rows, to: all)
        update(\.totalVisible, to: UInt64(all.count))
        update(\.journalSections, to: sections)
        update(\.hasOlderJournals, to: past.count > journalStreamDays)
        update(\.breadcrumb, to: [])
    }

    private func reconcileFocusAndSelection() {
        if let focused = focusedBlockId, !rows.contains(where: { $0.id == focused }) {
            endEditing()
        }
        if !selectedBlockIds.isEmpty {
            let live = Set(rows.map(\.id))
            selectedBlockIds.formIntersection(live)
            if selectedBlockIds.isEmpty {
                selectionAnchorId = nil
                selectionFocusId = nil
            }
        }
    }

    public func loadMoreRows() {
        guard hasMoreRows, let pageId = selectedPageId else { return }
        let interval = signposter.beginInterval("loadMore")
        defer { signposter.endInterval("loadMore", interval) }
        run {
            let nextOffset = windowOffset + UInt64(rows.count)
            let window = if let zoomed = zoomedBlockId {
                try graph.readBlockWindow(blockId: zoomed, offset: nextOffset, limit: pageWindowLimit)
            } else {
                try graph.readPageWindow(pageId: pageId, offset: nextOffset, limit: pageWindowLimit)
            }
            let existing = Set(rows.map(\.id))
            rows.append(contentsOf: window.rows.filter { !existing.contains($0.id) })
            totalVisible = window.totalVisible
        }
    }

    public func loadEarlierRows() {
        guard hasEarlierRows, let pageId = selectedPageId else { return }
        let interval = signposter.beginInterval("loadEarlier")
        defer { signposter.endInterval("loadEarlier", interval) }
        run {
            let start = windowOffset > pageWindowLimit ? windowOffset - pageWindowLimit : 0
            let window = try graph.readPageWindow(pageId: pageId, offset: start, limit: windowOffset - start)
            let existing = Set(rows.map(\.id))
            let anchor = rows.first?.id
            windowOffset = start
            update(\.rows, to: window.rows.filter { !existing.contains($0.id) } + rows)
            update(\.totalVisible, to: window.totalVisible)
            if let anchor {
                earlierRowsAnchor = EarlierRowsAnchor(blockId: anchor, seq: (earlierRowsAnchor?.seq ?? 0) &+ 1)
            }
        }
    }

    public func selectPage(_ pageId: String) {
        pushHistoryIfNeeded(for: .page(id: pageId, zoomedBlockId: nil))
        clearSelection()
        leaveBlock()
        isJournalStream = false
        listScreen = nil
        zoomedBlockId = nil
        windowOffset = 0
        pendingJournalTitle = nil
        selectedPageId = pageId
        unlinkedRefs = []
        unlinkedRefsLoaded = false
        closeFind()
        rows = []
        loadView()
    }

    public func openTodayJournal() {
        openJournal(date: todayTitle, asStream: true)
    }

    public func openJournal(date: String) {
        openJournal(date: date, asStream: false)
    }

    private func openJournal(date: String, asStream: Bool) {
        let target: NavTarget = if asStream {
            .journals
        } else if let existing = try? graph.journalPage(date: date) {
            .page(id: existing.id, zoomedBlockId: nil)
        } else {
            .pendingJournal(title: date)
        }
        pushHistoryIfNeeded(for: target)
        clearSelection()
        leaveBlock()
        isJournalStream = asStream
        if asStream {
            journalStreamDays = Self.journalStreamStep
        }
        listScreen = nil
        zoomedBlockId = nil
        windowOffset = 0
        rows = []
        do {
            if let journal = try graph.journalPage(date: date) {
                pendingJournalTitle = nil
                selectedPageId = journal.id
            } else {
                selectedPageId = nil
                pendingJournalTitle = try journalTitle(date: date)
            }
            loadView()
        } catch {
            report(error)
        }
    }

    public func stepJournalDay(_ delta: Int) {
        let base = currentJournalDate ?? todayTitle
        run {
            let target = try shiftJournalDay(date: base, deltaDays: Int32(delta))
            openJournal(date: target)
        }
    }

    public func showAllPages() {
        pushHistoryIfNeeded(for: .allPages)
        clearSelection()
        leaveBlock()
        closeFind()
        isJournalStream = false
        listScreen = .allPages
        refreshPageSummaries()
    }

    @discardableResult
    public func refreshPageSummaries() -> Task<Void, Never> {
        summariesFlight.submit(())
    }

    public func showShortcuts() {
        pushHistoryIfNeeded(for: .shortcuts)
        clearSelection()
        leaveBlock()
        closeFind()
        isJournalStream = false
        listScreen = .shortcuts
    }

    public func showSettings() {
        pushHistoryIfNeeded(for: .settings)
        clearSelection()
        leaveBlock()
        closeFind()
        isJournalStream = false
        listScreen = .settings
    }

    public func renameCurrentPage(to newTitle: String) {
        guard let page = currentPage else { return }
        renamePage(page.id, to: newTitle)
    }

    public func renamePage(_ pageId: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let page = library[pageId],
              page.journalDay == nil,
              trimmed != page.title else { return }
        if selectedPageId == pageId {
            flushDraft()
        }
        run {
            _ = try graph.applyOps(
                ops: [.renamePage(id: page.id, title: trimmed, expectedVersion: page.version)],
                meta: meta("rename page")
            )
            applyChanges()
        }
    }

    public func deletePage(_ pageId: String) {
        guard let page = library[pageId] else { return }
        if selectedPageId == page.id {
            clearSelection()
            leaveBlock()
        }
        run {
            _ = try graph.applyOps(
                ops: [.deletePage(id: page.id, expectedVersion: page.version)],
                meta: meta("delete page")
            )
            applyChanges()
        }
    }

    public var paletteItems: [PaletteItem] {
        AppAction.allCases.compactMap { action in
            guard action.inPalette, isAvailable(action) else { return nil }
            return PaletteItem(action: action, title: title(for: action), shortcut: shortcuts.displayString(for: action))
        }
    }

    public func paletteItems(matching query: String) -> [PaletteItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return paletteItems.filter { $0.matches(words) }
    }

    public func isAvailable(_ action: AppAction) -> Bool {
        let onPage = listScreen == nil && zoomedBlockId == nil
        let editablePage = onPage && !isJournalStream && (currentPage.map { $0.journalDay == nil } ?? false)
        let inOutliner = listScreen == nil && (!rows.isEmpty || selectedPageId != nil)
        switch action {
        case .findInPage: return inOutliner
        case .expandAll, .collapseAll: return inOutliner && selectedPageId != nil
        case .toggleFavorite: return onPage && currentPage != nil
        case .renamePage, .deletePage: return editablePage
        case .previousDay, .nextDay: return isShowingJournal
        case .goBack: return canGoBack || zoomedBlockId != nil
        case .goForward: return canGoForward
        case .openPalette, .goToToday, .openJournals, .openAllPages, .searchShortcuts, .openShortcuts, .openSettings,
             .toggleSidebar, .toggleTheme:
            return true
        case .focusEditor: return listScreen == nil
        case .cycleTask, .bold, .italic, .strikethrough, .highlight, .moveBlockUp, .moveBlockDown,
             .toggleBlockCollapse, .copyBlockMarkdown:
            return focusedBlockId != nil
        case .moveSelectionUp, .moveSelectionDown, .cycleSelectedTasks, .selectAllBlocks:
            return hasBlockSelection
        }
    }

    public func perform(_ action: AppAction) {
        guard isAvailable(action) else { return }
        switch action {
        case .findInPage: openFind()
        case .expandAll: setAllCollapsed(false)
        case .collapseAll: setAllCollapsed(true)
        case .toggleFavorite:
            if let page = currentPage { toggleFavorite(page.id) }
        case .renamePage:
            renameRequest &+= 1
        case .deletePage:
            pendingPageDelete = currentPage
        case .goToToday: goToToday()
        case .focusEditor: focusEditor()
        case .openJournals: openTodayJournal()
        case .previousDay: stepJournalDay(-1)
        case .nextDay: stepJournalDay(1)
        case .openAllPages: showAllPages()
        case .openShortcuts: showShortcuts()
        case .openSettings: showSettings()
        case .goBack: goBack()
        case .goForward: goForward()
        case .moveSelectionUp: moveSelectedBlocks(up: true)
        case .moveSelectionDown: moveSelectedBlocks(up: false)
        case .cycleSelectedTasks: cycleSelectedTasks()
        case .selectAllBlocks: selectAllBlocks()
        case .openPalette, .searchShortcuts, .toggleSidebar, .toggleTheme, .cycleTask, .bold, .italic, .strikethrough,
             .highlight, .moveBlockUp, .moveBlockDown, .toggleBlockCollapse, .copyBlockMarkdown:
            break
        }
    }

    public func requestDelete(_ pageId: String) {
        pendingPageDelete = library[pageId].flatMap { $0.journalDay == nil ? $0 : nil }
    }

    public func confirmPendingDelete() {
        guard let page = pendingPageDelete else { return }
        pendingPageDelete = nil
        deletePage(page.id)
    }

    public func requestRestorePage(id: String, title: String) {
        pendingPageRestore = (id: id, title: title)
    }

    public func confirmPendingRestore() {
        guard let pending = pendingPageRestore else { return }
        pendingPageRestore = nil
        run {
            _ = try graph.applyOps(ops: [.restorePage(id: pending.id)], meta: meta("restore page"))
            selectPage(pending.id)
        }
    }

    public func openBlock(id blockId: String) {
        run {
            let loc = try graph.revealBlockLocation(blockId: blockId, meta: meta("reveal block"))
            if selectedPageId != loc.pageId || zoomedBlockId != nil || listScreen != nil || isJournalStream {
                selectPage(loc.pageId)
            }
            if loc.visibleIndex >= windowOffset + pageWindowLimit {
                windowOffset = loc.visibleIndex - pageWindowLimit / 2
            }
            loadView()
            focusBlock(blockId)
        }
    }

    public func setAllCollapsed(_ collapsed: Bool) {
        flushDraft()
        run {
            if isJournalStream && zoomedBlockId == nil {
                for section in journalSections {
                    if let pid = section.pageId {
                        _ = try graph.setAllCollapsed(
                            pageId: pid,
                            rootBlockId: nil,
                            collapsed: collapsed,
                            meta: meta(collapsed ? "collapse all" : "expand all")
                        )
                    }
                }
            } else if let pageId = selectedPageId {
                _ = try graph.setAllCollapsed(
                    pageId: pageId,
                    rootBlockId: zoomedBlockId,
                    collapsed: collapsed,
                    meta: meta(collapsed ? "collapse all" : "expand all")
                )
            }
            applyChanges()
        }
    }

    public func openFind() {
        guard listScreen == nil else { return }
        find.isOpen = true
        refreshFindMatches(jumpToActive: false)
    }

    public func closeFind() {
        guard find.isOpen || !find.query.isEmpty || !find.matches.isEmpty || find.activeIndex != 0 else { return }
        find.isOpen = false
        find.query = ""
        find.matches = []
        find.activeIndex = 0
    }

    public func updateFindQuery(_ query: String) {
        find.query = query
        find.activeIndex = 0
        refreshFindMatches(jumpToActive: true)
    }

    public func nextFindMatch() {
        guard !find.matches.isEmpty else { return }
        find.activeIndex = (find.activeIndex + 1) % find.matches.count
        scrollToActiveFindMatch()
    }

    public func previousFindMatch() {
        guard !find.matches.isEmpty else { return }
        find.activeIndex = (find.activeIndex - 1 + find.matches.count) % find.matches.count
        scrollToActiveFindMatch()
    }

    private func refreshFindMatches(jumpToActive: Bool) {
        let trimmed = find.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            find.matches = []
            find.activeIndex = 0
            return
        }
        run {
            var found: [FfiPageMatch] = []
            if isJournalStream && zoomedBlockId == nil {
                for section in journalSections {
                    if let pid = section.pageId {
                        found.append(contentsOf: try graph.findInPage(pageId: pid, rootBlockId: nil, query: trimmed))
                    }
                }
            } else if let pageId = selectedPageId {
                found = try graph.findInPage(pageId: pageId, rootBlockId: zoomedBlockId, query: trimmed)
            }
            if find.matches != found {
                find.matches = found
            }
            if find.activeIndex >= found.count {
                find.activeIndex = 0
            }
            if jumpToActive {
                scrollToActiveFindMatch()
            }
        }
    }

    private func scrollToActiveFindMatch() {
        guard let match = find.activeMatch else { return }
        if !rows.contains(where: { $0.id == match.blockId }) {
            run {
                let index = try graph.revealBlock(blockId: match.blockId, meta: meta("reveal match"))
                if !isJournalStream, index >= windowOffset + pageWindowLimit {
                    windowOffset = index - pageWindowLimit / 2
                }
                loadView()
            }
        }
        find.reveal(match.blockId)
    }

    public func previewPage(id: String) -> FfiLinkPreview? {
        try? graph.previewPage(pageId: id, maxLines: 6)
    }

    public func previewBlock(id: String) -> FfiLinkPreview? {
        try? graph.previewBlock(blockId: id, maxLines: 5)
    }

    public func loadUnlinkedReferences() {
        guard let pageId = selectedPageId, !isJournalStream else {
            unlinkedRefs = []
            unlinkedRefsLoaded = true
            return
        }
        run {
            unlinkedRefs = try graph.unlinkedReferences(pageId: pageId, limit: 50)
            unlinkedRefsLoaded = true
        }
    }

    public func linkUnlinkedReference(blockId: String) {
        guard let pageId = selectedPageId else { return }
        run {
            _ = try graph.linkUnlinkedReference(
                blockId: blockId,
                targetPageId: pageId,
                meta: meta("link unlinked reference")
            )
            applyChanges()
        }
    }

    public func title(for action: AppAction) -> String {
        if action == .toggleFavorite {
            return currentPage?.favorite == true ? "Remove from Favorites" : "Add to Favorites"
        }
        return action.title
    }

    public func toggleFavorite(_ pageId: String) {
        guard let page = library[pageId] else { return }
        run {
            _ = try graph.applyOps(
                ops: [.setPageFavorite(id: page.id, favorite: !page.favorite)],
                meta: meta(page.favorite ? "unfavorite page" : "favorite page")
            )
            applyChanges()
        }
    }

    public func goBack() {
        if let previous = backStack.popLast() {
            if let current = currentNavTarget() {
                forwardStack.append(current)
            }
            syncHistoryFlags()
            navigate(to: previous)
        } else if zoomedBlockId != nil {
            zoomOutOneLevel()
        }
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = currentNavTarget() {
            backStack.append(current)
        }
        syncHistoryFlags()
        navigate(to: next)
    }

    private func currentNavTarget() -> NavTarget? {
        if listScreen == .allPages { return .allPages }
        if listScreen == .shortcuts { return .shortcuts }
        if listScreen == .settings { return .settings }
        if isJournalStream && zoomedBlockId == nil { return .journals }
        if let id = selectedPageId { return .page(id: id, zoomedBlockId: zoomedBlockId) }
        if let title = pendingJournalTitle { return .pendingJournal(title: title) }
        return nil
    }

    private func pushHistoryIfNeeded(for next: NavTarget) {
        guard !isRestoringHistory, let current = currentNavTarget(), current != next else { return }
        backStack.append(current)
        if backStack.count > 100 {
            backStack.removeFirst(backStack.count - 100)
        }
        forwardStack.removeAll()
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    private func navigate(to target: NavTarget) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        clearSelection()
        leaveBlock()
        windowOffset = 0
        rows = []
        isJournalStream = false
        switch target {
        case .journals:
            listScreen = nil
            zoomedBlockId = nil
            isJournalStream = true
            if let today = try? graph.journalPage(date: nil) {
                selectedPageId = today.id
                pendingJournalTitle = nil
            } else {
                selectedPageId = nil
                pendingJournalTitle = todayTitle
            }
            loadView()
        case .allPages:
            listScreen = .allPages
            refreshPageSummaries()
        case .shortcuts:
            listScreen = .shortcuts
        case .settings:
            listScreen = .settings
        case let .pendingJournal(title):
            listScreen = nil
            zoomedBlockId = nil
            if let existing = try? graph.journalPage(date: title) {
                selectedPageId = existing.id
                pendingJournalTitle = nil
            } else {
                selectedPageId = nil
                pendingJournalTitle = title
            }
            loadView()
        case let .page(id, zoomed):
            listScreen = nil
            pendingJournalTitle = nil
            selectedPageId = id
            zoomedBlockId = zoomed
            loadView()
        }
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
        let interval = signposter.beginInterval("focus")
        defer { signposter.endInterval("focus", interval) }
        clearSelection()
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

    public func goToToday() {
        openTodayJournal()
        focusEndOfPage()
    }

    public func focusEditor() {
        guard focusedBlockId == nil else { return }
        if let last = lastEditedBlockId, let row = rows.first(where: { $0.id == last }) {
            focusBlock(row.id, cursorOffset: TextOffsets.length(BlockPresentation.editable(row).text))
            return
        }
        focusEndOfPage()
    }

    private func focusEndOfPage() {
        let pageRows = isJournalStream ? Array(rows[journalSections.first?.rowRange ?? 0..<0]) : rows
        guard let last = pageRows.last else {
            ensureFirstBlockAndFocus()
            return
        }
        focusBlock(last.id, cursorOffset: TextOffsets.length(BlockPresentation.editable(last).text))
    }

    public var hasBlockSelection: Bool {
        !selectedBlockIds.isEmpty
    }

    public func selectBlock(_ blockId: String) {
        guard rows.contains(where: { $0.id == blockId }) else { return }
        leaveBlock()
        selectedBlockIds = [blockId]
        selectionAnchorId = blockId
        selectionFocusId = blockId
    }

    public func selectBlockFromFocus() {
        guard let blockId = focusedBlockId else { return }
        selectBlock(blockId)
    }

    public func clearSelection() {
        guard !selectedBlockIds.isEmpty || selectionAnchorId != nil || selectionFocusId != nil else { return }
        selectedBlockIds = []
        selectionAnchorId = nil
        selectionFocusId = nil
    }

    public func enterSelectedBlock() {
        let target = selectionFocusId ?? selectionAnchorId ?? orderedSelectedBlockIds().first
        guard let target else { return }
        focusBlock(target)
    }

    public func selectAllBlocks() {
        let anchorPage = selectionAnchorId.flatMap { id in rows.first(where: { $0.id == id })?.pageId }
            ?? focusedBlockId.flatMap { id in rows.first(where: { $0.id == id })?.pageId }
            ?? rows.first?.pageId
        let pageRows = rows.filter { $0.pageId == anchorPage }
        guard !pageRows.isEmpty else { return }
        leaveBlock()
        selectedBlockIds = Set(pageRows.map(\.id))
        selectionAnchorId = pageRows.first?.id
        selectionFocusId = pageRows.last?.id
    }

    public func moveSelection(up: Bool) {
        guard !rows.isEmpty else { return }
        let current = selectionFocusId ?? selectionAnchorId ?? orderedSelectedBlockIds().first
        guard let current, let idx = rows.firstIndex(where: { $0.id == current }) else {
            selectBlock(rows[0].id)
            return
        }
        let nextIdx = max(0, min(rows.count - 1, idx + (up ? -1 : 1)))
        selectBlock(rows[nextIdx].id)
    }

    public func extendSelection(up: Bool) {
        guard !rows.isEmpty else { return }
        let delta = up ? -1 : 1
        if let focused = focusedBlockId, let idx = rows.firstIndex(where: { $0.id == focused }) {
            leaveBlock()
            let nextIdx = max(0, min(rows.count - 1, idx + delta))
            selectRange(fromIndex: idx, toIndex: nextIdx)
            return
        }
        guard let anchor = selectionAnchorId ?? orderedSelectedBlockIds().first,
              let anchorIdx = rows.firstIndex(where: { $0.id == anchor }) else { return }
        let focus = selectionFocusId ?? anchor
        let focusIdx = rows.firstIndex(where: { $0.id == focus }) ?? anchorIdx
        let nextIdx = max(0, min(rows.count - 1, focusIdx + delta))
        selectRange(fromIndex: anchorIdx, toIndex: nextIdx)
    }

    public func shiftClickBlock(_ blockId: String) {
        guard let targetIdx = rows.firstIndex(where: { $0.id == blockId }) else { return }
        let anchorId = selectionAnchorId ?? focusedBlockId ?? blockId
        let anchorIdx = rows.firstIndex(where: { $0.id == anchorId }) ?? targetIdx
        leaveBlock()
        selectRange(fromIndex: anchorIdx, toIndex: targetIdx)
    }

    public func orderedSelectedBlockIds() -> [String] {
        rows.map(\.id).filter { selectedBlockIds.contains($0) }
    }

    public func selectedBlocksMarkdown() -> String? {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return nil }
        var markdown: String?
        run { markdown = try graph.blocksMarkdown(blockIds: ids) }
        return markdown
    }

    public func deleteSelectedBlocks() {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return }
        let firstIdx = rows.firstIndex(where: { selectedBlockIds.contains($0.id) })
        let fallbackId: String? = firstIdx.flatMap { idx in
            if idx > 0 { return rows[idx - 1].id }
            return rows.first(where: { !selectedBlockIds.contains($0.id) })?.id
        }
        run {
            _ = try graph.deleteBlocks(blockIds: ids, meta: meta("delete blocks"))
            clearSelection()
            applyChanges()
            if let fallbackId, rows.contains(where: { $0.id == fallbackId }) {
                selectBlock(fallbackId)
            }
        }
    }

    public func indentSelectedBlocks() {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return }
        run {
            if try graph.indentBlocks(blockIds: ids, meta: meta("indent blocks")) != nil {
                applyChanges()
            }
        }
    }

    public func outdentSelectedBlocks() {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return }
        run {
            if try graph.outdentBlocks(blockIds: ids, meta: meta("outdent blocks")) != nil {
                applyChanges()
            }
        }
    }

    public func moveSelectedBlocks(up: Bool) {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return }
        run {
            let result = up
                ? try graph.moveBlocksUp(blockIds: ids, meta: meta("move blocks up"))
                : try graph.moveBlocksDown(blockIds: ids, meta: meta("move blocks down"))
            if result != nil {
                applyChanges()
            }
        }
    }

    public func cycleSelectedTasks() {
        let ids = orderedSelectedBlockIds()
        guard !ids.isEmpty else { return }
        run {
            if try graph.cycleTasks(blockIds: ids, meta: meta("cycle tasks")) != nil {
                applyChanges()
            }
        }
    }

    private func selectRange(fromIndex anchorIdx: Int, toIndex requestedFocusIdx: Int) {
        let page = rows[anchorIdx].pageId
        let pageStart = rows[..<anchorIdx].lastIndex(where: { $0.pageId != page }).map { $0 + 1 } ?? 0
        let pageEnd = rows[anchorIdx...].firstIndex(where: { $0.pageId != page }).map { $0 - 1 } ?? rows.count - 1
        let focusIdx = min(max(requestedFocusIdx, pageStart), pageEnd)
        let lower = min(anchorIdx, focusIdx)
        let upper = max(anchorIdx, focusIdx)
        selectedBlockIds = Set(rows[lower...upper].map(\.id))
        selectionAnchorId = rows[anchorIdx].id
        selectionFocusId = rows[focusIdx].id
    }

    public func ensureFirstBlockAndFocus() {
        let pageRows = isJournalStream ? Array(rows[journalSections.first?.rowRange ?? 0..<0]) : rows
        if let first = pageRows.first {
            focusBlock(first.id, cursorOffset: TextOffsets.length(BlockPresentation.editable(first).text))
            return
        }
        run {
            let outcome: FfiEditOutcome
            if let pageId = selectedPageId {
                outcome = try graph.appendBlock(pageId: pageId, text: "", meta: meta("new block"))
            } else {
                let targetDate = pendingJournalTitle
                outcome = try graph.startJournal(date: targetDate, meta: meta("start journal"))
                selectedPageId = try graph.journalPage(date: targetDate)?.id
                pendingJournalTitle = nil
            }
            apply(outcome)
        }
    }

    public func updateDraft(blockId: String, text: String, isComposing: Bool, caret: Int? = nil) {
        guard focusedBlockId == blockId else { return }
        draftText = text
        isComposingIME = isComposing
        if let caret, !isComposing {
            let context = completionContext(text: draftText, caret: UInt32(caret))
            isEditingRef = context != nil
            updateCompletion(context: context)
        } else {
            isEditingRef = false
        }
        debounceTask?.cancel()
        guard !isComposing, !isEditingRef else { return }
        scheduleDebounceSave()
    }

    public func updateCaret(blockId: String, caret: Int) {
        guard focusedBlockId == blockId, !isComposingIME else { return }
        let context = completionContext(text: draftText, caret: UInt32(caret))
        let wasEditingRef = isEditingRef
        isEditingRef = context != nil
        if context != completion?.context {
            updateCompletion(context: context)
        }
        if wasEditingRef && !isEditingRef && isDirty {
            scheduleDebounceSave()
        }
    }

    private func scheduleDebounceSave() {
        debounceTask?.cancel()
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
        let interval = signposter.beginInterval("save")
        defer { signposter.endInterval("save", interval) }
        do {
            let content = BlockPresentation.combine(prefix: editPrefix, body: draftText)
            _ = try graph.applyOps(
                ops: [.updateBlock(id: blockId, content: content, expectedVersion: draftBaseVersion)],
                meta: meta("edit block", group: undoGroup)
            )
            applyChanges()
            if let saved = rows.first(where: { $0.id == blockId }) {
                if editPrefix.isEmpty {
                    draftBaseVersion = saved.version
                    draftBaseText = draftText
                } else {
                    rebase(on: saved)
                }
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
                before: BlockPresentation.combine(prefix: editPrefix, body: before),
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
        let text = BlockPresentation.editable(target).text
        focusBlock(target.id, cursorOffset: TextOffsets.offsetInLastLine(atColumn: column, in: text))
    }

    public func moveFocusDown(column: Int) {
        guard let blockId = focusedBlockId,
              let idx = rows.firstIndex(where: { $0.id == blockId }),
              idx + 1 < rows.count else {
            return
        }
        let target = rows[idx + 1]
        let text = BlockPresentation.editable(target).text
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
                applyChanges()
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
            applyChanges()
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

    @discardableResult
    public func runSearch(_ query: String) -> Task<Void, Never> {
        searchFlight.submit(query)
    }

    public func searchSettled() async {
        await searchFlight.settled()
    }

    public func completionSettled() async {
        await completionFlight.settled()
    }



    public func openSearchHit(_ hit: FfiSearchHit) {
        switch hit {
        case let .page(pageId, _, _):
            selectPage(pageId)
        case let .block(blockId, pageId, _, _, _, cursor, _):
            selectPage(pageId)
            run {
                let index = try graph.revealBlock(blockId: blockId, meta: meta("reveal block"))
                if index >= windowOffset + pageWindowLimit {
                    windowOffset = index - pageWindowLimit / 2
                }
                loadView()
            }
            guard let row = rows.first(where: { $0.id == blockId }) else { return }
            focusBlock(blockId, cursorOffset: editOffset(fromRendered: Int(cursor), in: row))
        }
    }

    public func zoom(into blockId: String) {
        let pageId = rows.first(where: { $0.id == blockId })?.pageId ?? selectedPageId
        if let pageId {
            pushHistoryIfNeeded(for: .page(id: pageId, zoomedBlockId: blockId))
        }
        clearSelection()
        leaveBlock()
        isJournalStream = false
        if let pageId {
            selectedPageId = pageId
            pendingJournalTitle = nil
        }
        zoomedBlockId = blockId
        rows = []
        loadView()
    }

    public func zoomOut(to crumb: FfiCrumb) {
        if let pageId = selectedPageId {
            pushHistoryIfNeeded(for: .page(id: pageId, zoomedBlockId: crumb.blockId))
        }
        clearSelection()
        leaveBlock()
        zoomedBlockId = crumb.blockId
        rows = []
        loadView()
    }

    public func zoomOutOneLevel() {
        guard zoomedBlockId != nil, breadcrumb.count >= 2 else { return }
        zoomOut(to: breadcrumb[breadcrumb.count - 2])
    }

    public func moveFocusedBlock(up: Bool, caret: Int) {
        guard let blockId = focusedBlockId else { return }
        flushDraft()
        let caretFromEnd = TextOffsets.length(draftText) - caret
        run {
            let outcome = up
                ? try graph.moveBlockUp(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("move block up"))
                : try graph.moveBlockDown(blockId: blockId, baseVersion: draftBaseVersion, meta: meta("move block down"))
            if outcome != nil {
                refreshFocused(caretFromEnd: caretFromEnd)
            }
        }
    }

    public func toggleFocusedCollapse(caret: Int) {
        guard let blockId = focusedBlockId, let row = rows.first(where: { $0.id == blockId }), row.hasChildren else { return }
        flushDraft()
        let caretFromEnd = TextOffsets.length(draftText) - caret
        run {
            _ = try graph.applyOps(
                ops: [.setCollapsed(id: blockId, collapsed: !row.collapsed)],
                meta: meta("toggle collapse")
            )
            refreshFocused(caretFromEnd: caretFromEnd)
        }
    }

    public func paste(_ pasted: String, selectionStart: Int, selectionEnd: Int) -> Bool {
        guard let blockId = focusedBlockId else { return false }
        cancelPendingSave()
        let (before, rest) = TextOffsets.split(draftText, atScalar: selectionStart)
        let (_, after) = TextOffsets.split(rest, atScalar: selectionEnd - selectionStart)
        var handled = false
        run {
            guard let outcome = try graph.pasteText(
                blockId: blockId,
                baseVersion: draftBaseVersion,
                before: BlockPresentation.combine(prefix: editPrefix, body: before),
                after: after,
                pasted: pasted,
                meta: meta("paste")
            ) else { return }
            handled = true
            apply(outcome)
        }
        return handled
    }

    public func focusedBlockMarkdown() -> String? {
        guard let blockId = focusedBlockId else { return nil }
        flushDraft()
        var markdown: String?
        run { markdown = try graph.subtreeMarkdown(blockId: blockId) }
        return markdown
    }

    public func moveCompletion(_ delta: Int) {
        guard var state = completion, !state.items.isEmpty else { return }
        state.selected = (state.selected + delta + state.items.count) % state.items.count
        completion = state
    }

    public func acceptCompletion(at index: Int? = nil) {
        guard let state = completion else { return }
        let chosen = index ?? state.selected
        guard state.items.indices.contains(chosen) else { return }
        let item = state.items[chosen]
        if let command = item.slash {
            runSlashCommand(command, context: state.context)
            return
        }
        let value = item.value
        clearCompletion()
        isEditingRef = false
        let edit = applyCompletion(text: draftText, context: state.context, value: value)
        draftText = edit.text
        requestCursor(Int(edit.caret))
        flushDraft()
    }

    public func dismissCompletion() {
        clearCompletion()
    }

    private func updateCompletion(context: FfiCompletionContext?) {
        guard let context else {
            clearCompletion()
            return
        }
        let interval = signposter.beginInterval("completion")
        defer { signposter.endInterval("completion", interval) }
        completionTicket &+= 1
        var items: [CompletionItem] = []
        switch context.kind {
        case .page, .tag:
            let pages = (try? graph.suggestPages(query: context.query, limit: 8)) ?? []
            items = pages.map { CompletionItem(label: $0.title, detail: nil, value: $0.title, isNew: false) }
            let query = context.query.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty, !pages.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
                items.append(CompletionItem(label: query, detail: "New page", value: query, isNew: true))
            }
        case .block:
            guard context.query.count >= 3 else {
                clearCompletion()
                return
            }
            requestBlockCompletion(context)
            return
        case .slash:
            items = slashCommands(matching: context.query)
        }
        completion = items.isEmpty ? nil : CompletionState(context: context, items: items, selected: 0)
    }

    private func clearCompletion() {
        completionTicket &+= 1
        update(\.completion, to: nil)
    }

    private func requestBlockCompletion(_ context: FfiCompletionContext) {
        completionFlight.submit(BlockCompletionJob(context: context, editing: focusedBlockId, ticket: completionTicket))
    }

    private func completeBlockReference(_ job: BlockCompletionJob) async {
        let query = job.context.query
        guard let hits = try? await worker.run({ try $0.search(query: query, limit: 20) }),
              !completionFlight.hasPending, job.ticket == completionTicket, focusedBlockId == job.editing else { return }
        let items: [CompletionItem] = hits.compactMap { hit in
            guard case let .block(blockId, _, _, breadcrumb, snippet, _, _) = hit, blockId != job.editing else {
                return nil
            }
            return CompletionItem(
                label: snippet.map(\.text).joined(),
                detail: SearchPresentation.breadcrumb(breadcrumb),
                value: blockId,
                isNew: false
            )
        }
        update(\.completion, to: items.isEmpty ? nil : CompletionState(context: job.context, items: items, selected: 0))
    }

    private func slashCommands(matching query: String) -> [CompletionItem] {
        let commands = (try? PithCore.slashCommands(query: query)) ?? []
        return commands.map { CompletionItem(label: $0.label, detail: $0.detail, value: $0.label, isNew: false, slash: $0.command) }
    }

    private func runSlashCommand(_ command: FfiSlashCommand, context: FfiCompletionContext) {
        guard let blockId = focusedBlockId else { return }
        cancelPendingSave()
        clearCompletion()
        isEditingRef = false
        let caret = TextOffsets.length(editPrefix) + Int(context.end)
        run {
            guard let outcome = try graph.runSlashCommand(
                blockId: blockId,
                baseVersion: draftBaseVersion,
                text: editPrefix + draftText,
                caret: UInt32(caret),
                command: command,
                meta: meta("slash command")
            ) else { return }
            apply(outcome)
        }
    }

    public func pollExternalChanges() {
        do {
            let currentVersion = try graph.dataVersion()
            guard currentVersion != lastDataVersion else { return }
            lastDataVersion = currentVersion
            applyChanges()
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
        loadEverything()
    }

    private func beginEditing(_ row: FfiFlatBlockRow) {
        lastEditedBlockId = row.id
        focusedBlockId = row.id
        rebase(on: row)
        draftText = draftBaseText
        undoGroup = newId()
    }

    private func endEditing() {
        cancelPendingSave()
        clearCompletion()
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
        isEditingRef = false
    }

    private func command(_ body: () throws -> FfiEditOutcome?) {
        run {
            guard let outcome = try body() else { return }
            apply(outcome)
        }
    }

    private func apply(_ outcome: FfiEditOutcome) {
        applyChanges()
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
        applyChanges()
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

    private func refreshFocused(caretFromEnd: Int) {
        applyChanges()
        guard let blockId = focusedBlockId, let row = rows.first(where: { $0.id == blockId }) else { return }
        rebase(on: row)
        draftText = draftBaseText
        requestCursor(max(0, TextOffsets.length(draftText) - caretFromEnd))
    }

    private func rebase(on row: FfiFlatBlockRow) {
        let editable = BlockPresentation.editable(row)
        draftBaseVersion = row.version
        draftBaseText = editable.text
        editPrefix = editable.prefix
    }

    private func editOffset(fromRendered offset: Int, in row: FfiFlatBlockRow) -> Int {
        max(0, offset - TextOffsets.length(BlockPresentation.editable(row).prefix))
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
