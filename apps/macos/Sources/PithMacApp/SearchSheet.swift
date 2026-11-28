import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct QuickSearchSheet: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var search: PaletteSearch
    @ObservedObject var settings: AppSettings = .shared
    @Binding var isPresented: Bool
    let layout: PaletteLayout
    var onDismiss: () -> Void = {}
    let onCommand: (AppAction) -> Void
    @State private var filter: PaletteFilter = .all
    @State private var selectedId: String?
    @State private var expanded: Set<String> = []
    @State private var commands: [ScoredCommand] = []
    @State private var preview: (rowId: String, value: PalettePreview?)?
    @State private var shortcutIndex: Int = 0
    @State private var recording: AppAction?
    @State private var problem: (combo: KeyCombo, problem: BindingProblem)?
    @State private var conflict: (combo: KeyCombo, actions: [AppAction])?
    @Namespace private var chips
    @FocusState private var inputFocused: Bool

    private var scope: PaletteScope {
        search.scope
    }

    private var query: String {
        search.input
    }

    private var parsed: PaletteQuery {
        PaletteQuery(query)
    }

    private var activeFilter: PaletteFilter {
        parsed.forcesCommands ? .commands : filter
    }

    private var results: PaletteResults {
        let text = parsed.text
        let hits = search.query.trimmingCharacters(in: .whitespacesAndNewlines) == text && !parsed.forcesCommands ? search.hits : []
        return PaletteResults.build(
            query: text,
            filter: activeFilter,
            hits: hits,
            commands: commands,
            recents: controller.recentPages,
            expanded: expanded
        )
    }

    private var selectedRow: PaletteRow? {
        let rows = results.rows
        return rows.first { $0.id == selectedId } ?? rows.first
    }

    private var shortcutSections: [(category: ShortcutCategory, actions: [AppAction])] {
        shortcuts.sections(matching: parsed.text)
    }

    private var shortcutActions: [AppAction] {
        shortcutSections.flatMap(\.actions)
    }

    private var builtInGroups: [(context: BuiltInContext, keys: [BuiltInKey])] {
        let keys = BuiltInKey.matching(parsed.text)
        return BuiltInContext.allCases.compactMap { context in
            let inContext = keys.filter { $0.context == context }
            return inContext.isEmpty ? nil : (context, inContext)
        }
    }

    private var selectedCommand: AppAction? {
        switch scope {
        case .everything:
            if case let .command(item)? = selectedRow?.kind { return item.action }
            return nil
        case .shortcuts:
            return shortcutActions.indices.contains(shortcutIndex) ? shortcutActions[shortcutIndex] : nil
        }
    }

    private var canCreate: Bool {
        results.rows.contains { $0.id == "create" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            if scope == .everything {
                filterRow
            }
            HStack(spacing: 0) {
                list
                    .frame(width: layout.showsSidePreview && scope == .everything ? PaletteLayout.listWidth : nil)
                if layout.showsSidePreview && scope == .everything {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    PreviewPane(row: selectedRow, preview: currentPreview, dateFormat: settings.dateFormat, shortcuts: shortcuts)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: layout.width, height: layout.height)
        .background(Theme.elevated)
        .animation(Motion.fast, value: recording)
        .onAppear {
            filter = .all
            search.input = ""
            refreshCommands()
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: scope) { _ in
            search.input = ""
            shortcutIndex = 0
            stopRecording()
        }
        .onChange(of: filter) { _ in
            selectedId = nil
        }
        .task(id: selectedRow?.id) {
            await loadPreview()
        }
        .keyScope(.overlay, whileEditingText: true, isActive: isPresented) { handleKey($0) }
    }

    private var currentPreview: PalettePreview? {
        guard let preview, preview.rowId == selectedRow?.id else { return nil }
        return preview.value
    }

    private func loadPreview() async {
        guard let row = selectedRow else {
            preview = nil
            return
        }
        let loaded = await controller.preview(for: row)
        guard !Task.isCancelled else { return }
        preview = (row.id, loaded)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            SearchIcon(size: 15)
                .foregroundColor(Theme.textTertiary)
            if scope == .shortcuts {
                Text("Shortcuts")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
            }
            TextField(scope == .shortcuts ? "Search shortcuts" : "Search pages and blocks, or type > for commands", text: $search.input)
                .textFieldStyle(.plain)
                .font(Typography.ui(TypeScale.searchInput))
                .foregroundColor(Theme.textStrong)
                .focused($inputFocused)
                .onChange(of: query) { _ in
                    if scope == .everything {
                        controller.runSearch(parsed.forcesCommands ? "" : parsed.text)
                    }
                    refreshCommands()
                    selectedId = nil
                    expanded = []
                    shortcutIndex = 0
                }
                .onSubmit(submit)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var filterRow: some View {
        HStack(spacing: 0) {
            ChipRow {
                ForEach(PaletteFilter.allCases, id: \.self) { option in
                    FilterChip(
                        title: option.title,
                        count: results.count(option),
                        isSelected: activeFilter == option,
                        namespace: chips,
                        selectionId: "palette-filter",
                        action: { choose(option) }
                    )
                }
            }
            if layout.showsAllHints {
                Spacer(minLength: 8)
                KeyHint(keys: "⇥", label: "Filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .animation(Motion.fast, value: activeFilter)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch scope {
                case .everything: resultList
                case .shortcuts: shortcutsList
                }
            }
            .onChange(of: selectedRow?.id) { id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
            .onChange(of: shortcutIndex) { proxy.scrollTo($0) }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        let rows = results.rows
        let selected = selectedRow?.id
        if rows.isEmpty {
            EmptyResults(query: parsed.text, filter: activeFilter)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if let section = row.section, index == 0 || rows[index - 1].section != section {
                        SectionLabel(title: section)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 6 : 14)
                            .padding(.bottom, 4)
                    }
                    ResultRow(
                        row: row,
                        dateFormat: settings.dateFormat,
                        isSelected: row.id == selected,
                        inlinePreview: !layout.showsSidePreview && row.id == selected ? currentPreview : nil,
                        keycaps: keycaps(for: row),
                        isCustomized: isCustomized(row),
                        isRecording: isRecording(row)
                    ) {
                        selectedId = row.id
                        activate(row)
                    }
                    .id(row.id)
                }
            }
            .padding(6)
        }
    }

    private func keycaps(for row: PaletteRow) -> [String] {
        switch row.kind {
        case let .command(item): return shortcuts.keycaps(for: item.action)
        case .create: return ["⌘", "↵"]
        default: return []
        }
    }

    private func isCustomized(_ row: PaletteRow) -> Bool {
        guard case let .command(item) = row.kind else { return false }
        return shortcuts.isCustomized(item.action)
    }

    private func isRecording(_ row: PaletteRow) -> Bool {
        guard case let .command(item) = row.kind else { return false }
        return recording == item.action
    }

    private var shortcutsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shortcutSections, id: \.category) { section in
                SectionLabel(title: section.category.title)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(section.actions) { action in
                    let position = shortcutActions.firstIndex(of: action) ?? 0
                    CommandRow(
                        title: action.title,
                        keycaps: shortcuts.keycaps(for: action),
                        isCustomized: shortcuts.isCustomized(action),
                        isSelected: shortcutIndex == position,
                        isRecording: recording == action
                    ) {
                        shortcutIndex = position
                        startRecording(action)
                    }
                    .id(position)
                }
            }
            ForEach(builtInGroups, id: \.context) { group in
                SectionLabel(title: "Built-in · \(group.context.title)")
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(group.keys) { key in
                    CommandRow(title: key.title, keycaps: key.keycaps, isCustomized: false, isSelected: false, isRecording: false, action: nil)
                }
            }
            if shortcutSections.isEmpty && builtInGroups.isEmpty {
                Text("No shortcuts match “\(parsed.text)”")
                    .font(Typography.ui(TypeScale.ui))
                    .foregroundColor(Theme.textTertiary)
                    .padding(12)
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let conflict, let recording {
                Text("\(conflict.combo.displayString) is used by \(conflict.actions.map(\.title).joined(separator: ", ")).")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(keys: "↵", label: "Replace")
                KeyHint(keys: "esc", label: "Keep \(recording.title)'s old key")
            } else if recording != nil {
                Text(problem.map { ShortcutsView.message(for: $0.problem, combo: $0.combo) } ?? "Press the new shortcut")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(keys: "⌫", label: "Clear")
                KeyHint(keys: "esc", label: "Cancel")
            } else {
                if layout.showsAllHints {
                    KeyHint(keys: "↑↓", label: "Move")
                }
                switch scope {
                case .everything:
                    if let label = primaryLabel {
                        KeyHint(keys: "↵", label: label)
                    }
                    if selectedCommand != nil {
                        KeyHint(keys: "⌘↵", label: "Change shortcut")
                    } else if canCreate {
                        KeyHint(keys: "⌘↵", label: "Create page")
                    }
                case .shortcuts:
                    KeyHint(keys: "↵", label: "Change shortcut")
                    KeyHint(keys: "⌫", label: "All commands")
                }
                Spacer(minLength: 0)
                KeyHint(keys: "esc", label: "Close")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var primaryLabel: String? {
        switch selectedRow?.kind {
        case .page, .block: return "Open"
        case .command: return "Run"
        case .more: return "Show all"
        case .create: return "Create"
        case nil: return nil
        }
    }

    private func handleKey(_ stroke: KeyStroke) -> Bool {
        if let recording {
            record(stroke, for: recording)
            return true
        }
        if let action = shortcuts.action(matching: stroke, in: .global), action == .openPalette || action == .searchShortcuts {
            let target: PaletteScope = action == .searchShortcuts ? .shortcuts : .everything
            if scope == target {
                onDismiss()
            } else {
                search.scope = target
            }
            return true
        }
        switch (stroke.key, stroke.modifiers) {
        case (.escape, []):
            onDismiss()
        case (.returnKey, []):
            submit()
        case (.returnKey, [.command]):
            if let action = selectedCommand {
                startRecording(action)
            } else if canCreate {
                createPage()
            }
        case (.tab, []) where scope == .everything && !parsed.forcesCommands:
            choose(filter.next)
        case (.tab, [.shift]) where scope == .everything && !parsed.forcesCommands:
            choose(filter.previous)
        case (.backspace, []) where scope == .shortcuts && query.isEmpty:
            search.scope = .everything
        case (.down, []):
            moveSelection(1)
        case (.up, []):
            moveSelection(-1)
        default:
            return false
        }
        return true
    }

    private func choose(_ option: PaletteFilter) {
        filter = option
        expanded = []
    }

    private func refreshCommands() {
        commands = controller.paletteCommands(matching: parsed.text)
    }

    private func record(_ stroke: KeyStroke, for action: AppAction) {
        if let pending = conflict {
            switch (stroke.key, stroke.modifiers) {
            case (.returnKey, []):
                shortcuts.set(pending.combo, for: action, clearConflicts: true)
                stopRecording()
                return
            case (.escape, []):
                stopRecording()
                return
            default:
                conflict = nil
            }
        }
        switch shortcuts.record(stroke, for: action) {
        case .cancelled, .cleared, .bound:
            stopRecording()
        case .ignored:
            break
        case let .rejected(combo, reason):
            problem = (combo, reason)
        case let .conflict(combo, actions):
            problem = nil
            conflict = (combo, actions)
        }
    }

    private func startRecording(_ action: AppAction) {
        recording = action
        problem = nil
        conflict = nil
    }

    private func stopRecording() {
        recording = nil
        problem = nil
        conflict = nil
    }

    private func moveSelection(_ delta: Int) {
        switch scope {
        case .everything:
            let rows = results.rows
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { $0.id == selectedRow?.id } ?? 0
            selectedId = rows[(current + delta + rows.count) % rows.count].id
        case .shortcuts:
            let count = shortcutActions.count
            guard count > 0 else { return }
            shortcutIndex = (shortcutIndex + delta + count) % count
        }
    }

    private func submit() {
        Task {
            await controller.searchSettled()
            switch scope {
            case .everything:
                if let row = selectedRow {
                    activate(row)
                }
            case .shortcuts:
                if let action = selectedCommand {
                    startRecording(action)
                }
            }
        }
    }

    private func activate(_ row: PaletteRow) {
        switch row.kind {
        case let .command(item):
            isPresented = false
            onCommand(item.action)
        case let .more(pageId, _, hidden):
            expanded.insert(pageId)
            selectedId = hidden.first.map { PaletteRow.id(for: $0) }
        case .page, .block, .create:
            controller.open(row)
            isPresented = false
        }
    }

    private func createPage() {
        controller.openPageByTitle(parsed.text)
        isPresented = false
    }
}

private struct EmptyResults: View {
    let query: String
    let filter: PaletteFilter

    var body: some View {
        Text(message)
            .font(Typography.ui(TypeScale.ui))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    private var message: String {
        if query.isEmpty {
            return filter == .blocks ? "Type to search inside your pages" : "Nothing here yet"
        }
        return "No \(filter == .all ? "results" : filter.title.lowercased()) for “\(query)”"
    }
}

private enum RowMetrics {
    static let iconColumn: CGFloat = 16
    static let gap: CGFloat = 10
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let singleLineHeight: CGFloat = 36
}

private struct RowIcon: View {
    let kind: PaletteRowKind
    let isSelected: Bool

    var body: some View {
        Group {
            switch kind {
            case let .page(page):
                if page.isJournal { TodayIcon() } else { PageIcon() }
            case .block:
                Circle()
                    .fill(isSelected ? Theme.accent : Theme.bullet)
                    .frame(width: 5, height: 5)
                    .frame(width: 14, height: 14)
            case .command:
                CommandIcon()
            case .more:
                MoreIcon()
            case .create:
                PlusIcon().frame(width: 14, height: 14)
            }
        }
        .foregroundColor(iconColor)
        .frame(width: RowMetrics.iconColumn)
    }

    private var iconColor: Color {
        if case .create = kind { return Theme.accent }
        return isSelected ? Theme.textSecondary : Theme.textTertiary
    }
}

private struct ResultRow: View {
    let row: PaletteRow
    let dateFormat: JournalDateFormat
    let isSelected: Bool
    let inlinePreview: PalettePreview?
    let keycaps: [String]
    let isCustomized: Bool
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: RowMetrics.gap) {
                    RowIcon(kind: row.kind, isSelected: isSelected)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    VStack(alignment: .leading, spacing: 3) {
                        primary
                        secondary
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                if let inlinePreview {
                    InlineContext(preview: inlinePreview)
                        .padding(.leading, RowMetrics.iconColumn + RowMetrics.gap)
                }
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, RowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: RowMetrics.singleLineHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.rowSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }

    @ViewBuilder
    private var primary: some View {
        switch row.kind {
        case let .page(page):
            Text(page.isJournal ? AttributedString(SearchPresentation.displayTitle(page.title, isJournal: true, format: dateFormat)) : SearchPresentation.highlighted(page.highlighted))
                .font(Typography.ui(TypeScale.listRow, .medium))
                .foregroundColor(Theme.textStrong)
                .lineLimit(1)
        case let .block(block):
            Text(SearchPresentation.highlighted(block.snippet))
                .font(Typography.ui(TypeScale.listRow))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case let .command(item):
            Text(item.title)
                .font(Typography.ui(TypeScale.listRow))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        case let .more(_, pageTitle, hidden):
            Text("\(hidden.count) more in \(SearchPresentation.displayTitle(pageTitle, isJournal: hidden.first?.pageIsJournal ?? false, format: dateFormat))")
                .font(Typography.ui(TypeScale.listRow))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        case let .create(title):
            (Text("Create page ").foregroundColor(Theme.textStrong) + Text("“\(title)”").foregroundColor(Theme.textSecondary))
                .font(Typography.ui(TypeScale.listRow, .medium))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if case let .block(block) = row.kind {
            Text(SearchPresentation.crumbs(of: block, format: dateFormat))
                .font(Typography.ui(TypeScale.meta))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch row.kind {
        case let .page(page):
            if let label = SearchPresentation.pageAccessory(isJournal: page.isJournal, backlinks: page.backlinkCount) {
                Text(label)
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .command, .create:
            if isRecording {
                Text("Press shortcut…")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            } else if !keycaps.isEmpty {
                KeycapRow(caps: keycaps, tint: isCustomized ? Theme.accent : Theme.textSecondary)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            }
        case .block, .more:
            EmptyView()
        }
    }
}

private struct InlineContext: View {
    let preview: PalettePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(InlineFormatter.format(line.spans, muted: true))
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.guide).frame(width: 2) }
    }

    private var lines: [(depth: UInt32, spans: [FfiSpan])] {
        switch preview {
        case let .page(page):
            return page.lines.prefix(3).map { ($0.depth, $0.spans) }
        case let .block(context):
            guard let target = context.lines.firstIndex(where: \.isTarget) else { return [] }
            let around = context.lines.enumerated().filter { index, _ in index != target && abs(index - target) <= 2 }
            return around.prefix(3).map { ($0.element.depth, $0.element.spans) }
        }
    }
}

private struct PreviewPane: View {
    let row: PaletteRow?
    let preview: PalettePreview?
    let dateFormat: JournalDateFormat
    let shortcuts: ShortcutStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let row {
                    header(for: row)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    content(for: row)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func header(for row: PaletteRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: SearchPresentation.kindLabel(row.kind))
            Text(SearchPresentation.previewTitle(row.kind, format: dateFormat))
                .font(Typography.ui(TypeScale.searchInput, .semibold))
                .foregroundColor(Theme.textStrong)
                .lineLimit(2)
            if let meta = SearchPresentation.previewMeta(row.kind, preview: preview) {
                Text(meta)
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func content(for row: PaletteRow) -> some View {
        switch (row.kind, preview) {
        case let (.page, .page(page)?):
            if page.lines.isEmpty {
                PreviewNote(text: "This page is empty.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(page.lines.enumerated()), id: \.offset) { _, line in
                        OutlineLine(depth: line.depth, spans: line.spans, isTarget: false)
                    }
                }
                if page.totalBlocks > UInt64(page.lines.count) {
                    PreviewNote(text: "+\(page.totalBlocks - UInt64(page.lines.count)) more blocks")
                }
            }
        case let (.block, .block(context)?):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(context.lines.enumerated()), id: \.offset) { _, line in
                    OutlineLine(depth: line.depth, spans: line.spans, isTarget: line.isTarget)
                }
            }
        case let (.command(item), _):
            VStack(alignment: .leading, spacing: 10) {
                let caps = shortcuts.keycaps(for: item.action)
                if caps.isEmpty {
                    PreviewNote(text: "No shortcut yet.")
                } else {
                    KeycapRow(caps: caps, tint: shortcuts.isCustomized(item.action) ? Theme.accent : Theme.textSecondary)
                }
                PreviewNote(text: "↵ runs it · ⌘↵ changes its shortcut")
            }
        case let (.more(_, _, hidden), _):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(hidden, id: \.id) { block in
                    Text(SearchPresentation.highlighted(block.snippet))
                        .font(Typography.ui(TypeScale.ui))
                        .foregroundColor(Theme.textBody)
                        .lineLimit(2)
                }
            }
        case let (.create(title), _):
            PreviewNote(text: "Creates “\(title)” and puts the cursor in its first block.")
        default:
            EmptyView()
        }
    }
}

private struct CommandRow: View {
    let title: String
    let keycaps: [String]
    let isCustomized: Bool
    let isSelected: Bool
    let isRecording: Bool
    let action: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHovered = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Typography.ui(TypeScale.listRow))
                .foregroundColor(action == nil ? Theme.textSecondary : Theme.textPrimary)
            Spacer()
            if isRecording {
                Text("Press shortcut…")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
            } else {
                KeycapRow(caps: keycaps, tint: isCustomized ? Theme.accent : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.rowSelected : isHovered && action != nil ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
    }
}
