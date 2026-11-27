import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct OutlinerView: View {
    @ObservedObject var controller: OutlinerController
    let contentLeading: CGFloat
    let contentWidth: CGFloat
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        HStack(spacing: 0) {
                            content
                                .frame(width: contentWidth, alignment: .leading)
                                .padding(.leading, contentLeading)
                                .padding(.top, 58)
                                .padding(.bottom, 140)
                            Spacer(minLength: 0)
                        }
                    }
                    .onChange(of: controller.focusedBlockId) { newId in
                        if let id = newId {
                            proxy.scrollTo(id)
                        }
                    }
                    .onChange(of: controller.scrollTargetSeq) { _ in
                        if let id = controller.scrollTargetBlockId {
                            withAnimation(Motion.fast) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }

            if controller.isFindOpen {
                FindBar(controller: controller)
                    .padding(.top, 44)
                    .padding(.trailing, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(5)
            }
        }
        .animation(Motion.fast, value: controller.isFindOpen)
        .keyScope(.screen) { handleKey($0) }
        .environment(\.openURL, OpenURLAction { url in
            if let pageId = InlineFormatter.pageId(from: url) {
                controller.openPage(id: pageId)
                return .handled
            }
            return .systemAction
        })
    }

    private func handleKey(_ stroke: KeyStroke) -> Bool {
        guard controller.hasBlockSelection else {
            guard controller.focusedBlockId == nil else { return false }
            switch (stroke.key, stroke.modifiers) {
            case (.down, []), (.returnKey, []):
                controller.ensureFirstBlockAndFocus()
                return true
            default:
                return false
            }
        }

        switch (stroke.key, stroke.modifiers) {
        case (.escape, []):
            controller.clearSelection()
        case (.returnKey, []):
            controller.enterSelectedBlock()
        case (.returnKey, .command):
            controller.cycleSelectedTasks()
        case (.backspace, []), (.forwardDelete, []):
            controller.deleteSelectedBlocks()
        case (.tab, []):
            controller.indentSelectedBlocks()
        case (.tab, .shift):
            controller.outdentSelectedBlocks()
        case (.up, []):
            controller.moveSelection(up: true)
        case (.down, []):
            controller.moveSelection(up: false)
        case (.up, .shift):
            controller.extendSelection(up: true)
        case (.down, .shift):
            controller.extendSelection(up: false)
        case (.up, .option):
            controller.moveSelectedBlocks(up: true)
        case (.down, .option):
            controller.moveSelectedBlocks(up: false)
        case (.character("c"), .command):
            copySelectedBlocks()
        case (.character("x"), .command):
            copySelectedBlocks()
            controller.deleteSelectedBlocks()
        case (.character("a"), .command):
            controller.selectAllBlocks()
        default:
            return false
        }
        return true
    }

    private func copySelectedBlocks() {
        guard let markdown = controller.selectedBlocksMarkdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.zoomedBlockId != nil {
                ZoomTrailView(controller: controller)
                    .padding(.bottom, 18)
            } else {
                pageHeader
            }

            if controller.zoomedBlockId != nil {
                EmptyView()
            } else if let subtitle {
                Text(subtitle)
                    .font(Typography.ui(13))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
            } else {
                Spacer().frame(height: 26)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.danger)
                    .padding(.bottom, 10)
            }

            if controller.isJournalStream {
                journalStream
            } else if controller.rows.isEmpty {
                startWriting
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rows, id: \.id) { row in
                        outlineRow(row)
                    }
                    if controller.hasMoreRows {
                        Button {
                            controller.loadMoreRows()
                        } label: {
                            let remaining = controller.totalVisible - UInt64(controller.rows.count)
                            Text("Load more (\(remaining) remaining)")
                                .font(Typography.ui(12, .medium))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.vertical, 12)
                                .padding(.leading, 40)
                        }
                        .buttonStyle(.plain)
                        .onAppear { controller.loadMoreRows() }
                    }
                }
            }

            if !controller.backlinks.isEmpty {
                LinkedReferences(controller: controller)
                    .padding(.top, 52)
            }

            if controller.selectedPageId != nil,
               !controller.isJournalStream,
               controller.zoomedBlockId == nil,
               controller.currentPage?.journalDay == nil {
                UnlinkedReferences(controller: controller)
                    .padding(.top, controller.backlinks.isEmpty ? 52 : 24)
            }
        }
        .onChange(of: controller.selectedPageId) { _ in
            isRenaming = false
        }
        .onChange(of: controller.renameRequest) { _ in
            guard let page = controller.currentPage, page.journalDay == nil else { return }
            renameDraft = page.title
            isRenaming = true
        }
    }

    private var startWriting: some View {
        Button {
            controller.ensureFirstBlockAndFocus()
        } label: {
            HStack(spacing: OutlineRow.textGap) {
                Circle().fill(Theme.bullet).frame(width: 5, height: 5).frame(width: OutlineRow.markerWidth)
                Text("Start writing…")
                    .font(Typography.ui(15))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

    }

    private var journalStream: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(controller.journalSections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    JournalHeading(title: section.title) {
                        controller.openJournal(date: section.title)
                    }
                }
                if index == 0 && section.rowRange.isEmpty {
                    startWriting
                }
                ForEach(controller.rows[section.rowRange], id: \.id) { row in
                    outlineRow(row)
                }
            }
            if controller.hasOlderJournals {
                Text("Loading earlier days…")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 40)
                    .padding(.leading, 40)
                    .onAppear { controller.loadOlderJournals() }
            }
        }
    }

    private func outlineRow(_ row: FfiFlatBlockRow) -> some View {
        let isFocused = controller.focusedBlockId == row.id
        return OutlineRow(
            row: row,
            isFocused: isFocused,
            isSelected: controller.selectedBlockIds.contains(row.id),
            cursorOffset: isFocused ? controller.requestedCursorOffset : nil,
            cursorSeq: isFocused ? controller.cursorRequestSeq : 0,
            completion: isFocused ? controller.completion : nil,
            controller: controller
        )
        .padding(.leading, -OutlineRow.disclosureWidth)
        .id(row.id)
    }

    @ViewBuilder
    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if isRenaming {
                TextField("Page title", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($titleFieldFocused)
                    .onAppear { titleFieldFocused = true }
                    .font(Typography.ui(28, .semibold))
                    .foregroundColor(Theme.textStrong)
                    .onSubmit {
                        controller.renameCurrentPage(to: renameDraft)
                        isRenaming = false
                    }
                    .onExitCommand { isRenaming = false }
            } else if controller.isJournalStream {
                JournalTitleButton(title: controller.pageTitle ?? controller.todayTitle) {
                    controller.openJournal(date: controller.todayTitle)
                }
            } else {
                Text(controller.pageTitle ?? "")
                    .font(Typography.ui(28, .semibold))
                    .tracking(-0.4)
                    .foregroundColor(Theme.textStrong)
                    .onTapGesture(count: 2) {
                        guard let page = controller.currentPage, page.journalDay == nil else { return }
                        renameDraft = page.title
                        isRenaming = true
                    }
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if controller.isShowingToday {
            parts.append("Today")
        }
        if !controller.backlinks.isEmpty {
            let count = controller.backlinks.count
            parts.append(count == 1 ? "1 linked reference" : "\(count) linked references")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct OutlineRow: View {
    let row: FfiFlatBlockRow
    let isFocused: Bool
    let isSelected: Bool
    let cursorOffset: Int?
    let cursorSeq: UInt64
    let completion: CompletionState?
    let controller: OutlinerController
    @State private var isHovered = false

    static let indent: CGFloat = 24
    static let disclosureWidth: CGFloat = 14
    static let markerWidth: CGFloat = 18
    static let textGap: CGFloat = 8
    static let gutter: CGFloat = disclosureWidth + markerWidth + textGap
    private static let guideX: CGFloat = 22.5
    private static let rowPadding: CGFloat = 4

    var body: some View {
        let presentation = BlockPresentation.runs(row.display)
        let rowFindMatches = controller.findMatches(in: row.id)
        let activeFindOrdinal = controller.activeFindOrdinal(in: row.id)

        HStack(alignment: .top, spacing: 0) {
            disclosure
                .frame(width: Self.disclosureWidth, height: markerHeight)
            marker(presentation.status)
                .frame(width: Self.markerWidth, height: markerHeight)
            blockBody(
                presentation: presentation,
                findMatches: rowFindMatches,
                activeFindOrdinal: activeFindOrdinal
            )
            .padding(.leading, Self.textGap)
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.top, topPadding)
        .padding(.bottom, Self.rowPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.selected)
                    .padding(.horizontal, -6)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fast, value: isSelected)
        .background(alignment: .topLeading) { guides }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var markerHeight: CGFloat {
        guard !isFocused else { return BlockStyle.lineHeight }
        switch row.kind {
        case let .heading(level):
            return level == 1 ? 30 : (level == 2 ? 26 : BlockStyle.lineHeight)
        default:
            return BlockStyle.lineHeight
        }
    }

    private var topPadding: CGFloat {
        guard !isFocused else { return Self.rowPadding }
        switch row.kind {
        case let .heading(level):
            return level == 1 ? 12 : (level == 2 ? 8 : Self.rowPadding)
        default:
            return Self.rowPadding
        }
    }

    @ViewBuilder
    private func blockBody(
        presentation: (status: TaskStatus?, runs: [DisplayRun]),
        findMatches: [FfiPageMatch],
        activeFindOrdinal: Int?
    ) -> some View {
        if !isFocused, case .divider = row.kind {
            DividerBlockView {
                controller.focusBlock(row.id)
            }
        } else if !isFocused, case let .codeBlock(language, code) = row.kind {
            CodeBlockCard(language: language, code: code) {
                controller.focusBlock(row.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if isFocused || !presentation.runs.isEmpty || row.props.isEmpty {
                    let editor = BlockTextView(
                        blockId: row.id,
                        isEditing: isFocused,
                        display: BlockStyle.display(
                            presentation.runs,
                            closed: presentation.status?.isClosed ?? false,
                            kind: row.kind,
                            findMatches: findMatches,
                            activeFindOrdinal: activeFindOrdinal
                        ),
                        runs: presentation.runs,
                        text: Binding(get: { controller.draftText }, set: { controller.draftText = $0 }),
                        requestedCursorOffset: cursorOffset,
                        cursorRequestSeq: cursorSeq,
                        onActivate: { controller.focusBlock(row.id, cursorOffset: $0) },
                        onShiftClick: { controller.shiftClickBlock(row.id) },
                        onOpenPage: { controller.openPage(id: $0) },
                        onRestoreDeletedPage: { controller.requestRestorePage(id: $0, title: $1) },
                        onOpenBlockRef: { controller.openBlock(id: $0) },
                        onHoverPreview: { target in
                            switch target {
                            case let .page(pageId): return controller.previewPage(id: pageId)
                            case let .block(blockId): return controller.previewBlock(id: blockId)
                            }
                        },
                        onTextChange: { text, composing, caret in
                            controller.updateDraft(blockId: row.id, text: text, isComposing: composing, caret: caret)
                        },
                        onCaretChange: { caret in
                            controller.updateCaret(blockId: row.id, caret: caret)
                        },
                        onReturn: { controller.handleReturn(at: $0) },
                        onCycleTask: { controller.cycleTask(caret: $0) },
                        onBackspaceAtStart: { controller.handleBackspaceAtStart() },
                        onTab: { controller.indentFocusedBlock() },
                        onShiftTab: { controller.outdentFocusedBlock() },
                        onMoveUp: { controller.moveFocusUp(column: $0) },
                        onMoveDown: { controller.moveFocusDown(column: $0) },
                        onExtendSelectionUp: { controller.extendSelection(up: true) },
                        onExtendSelectionDown: { controller.extendSelection(up: false) },
                        onEscape: { controller.selectBlockFromFocus() },
                        completion: completion,
                        onCompletionMove: { controller.moveCompletion($0) },
                        onCompletionAccept: { controller.acceptCompletion(at: $0) },
                        onCompletionDismiss: { controller.dismissCompletion() },
                        onMoveBlock: { controller.moveFocusedBlock(up: $0, caret: $1) },
                        onToggleCollapse: { controller.toggleFocusedCollapse(caret: $0) },
                        onCopyMarkdown: {
                            guard let markdown = controller.focusedBlockMarkdown() else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(markdown, forType: .string)
                        },
                        onPaste: { controller.paste($0, selectionStart: $1, selectionEnd: $2) }
                    )

                    if !isFocused, case .quote = row.kind {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Theme.bullet)
                                .frame(width: 2)
                                .padding(.vertical, 3)
                            editor
                        }
                    } else {
                        editor
                    }
                }

                if !isFocused, !row.props.isEmpty {
                    PropertyChipsRow(props: row.props) {
                        controller.focusBlock(row.id)
                    }
                }
            }
        }
    }

    private var guides: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Int(row.depth), id: \.self) { level in
                Rectangle()
                    .fill(Theme.guide)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: CGFloat(level) * Self.indent + Self.guideX)
            }
            if row.hasChildren && !row.collapsed {
                Rectangle()
                    .fill(Theme.guide)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, Self.rowPadding + BlockStyle.lineHeight / 2 + 7)
                    .offset(x: CGFloat(row.depth) * Self.indent + Self.guideX)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button {
                controller.toggleCollapse(row.id)
            } label: {
                ChevronIcon(expanded: !row.collapsed)
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 14, height: BlockStyle.lineHeight)
                    .contentShape(Rectangle())
                    .opacity(isHovered ? 1 : 0)
                    .animation(Motion.fast, value: isHovered)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .accessibilityLabel(row.collapsed ? "Expand" : "Collapse")
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func marker(_ status: TaskStatus?) -> some View {
        if let status {
            Button {
                controller.toggleTaskDone(row.id)
            } label: {
                StatusIcon(status: status)
                    .frame(width: 18, height: BlockStyle.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle(scale: 0.88))
            .cursor(.pointingHand)
        } else {
            Button {
                controller.zoom(into: row.id)
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.bullet.opacity(row.hasChildren && row.collapsed ? 0.35 : (isHovered ? 0.18 : 0)))
                        .frame(width: 14, height: 14)
                        .scaleEffect((row.hasChildren && row.collapsed) || isHovered ? 1 : 0.4)
                    Circle()
                        .fill(isHovered ? Theme.textSecondary : Theme.bullet)
                        .frame(width: 5, height: 5)
                }
                .animation(Motion.morph, value: row.collapsed)
                .animation(Motion.hover, value: isHovered)
                .frame(width: 18, height: BlockStyle.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle(scale: 0.90))
            .cursor(.pointingHand)
            .accessibilityLabel(row.hasChildren && row.collapsed ? "Zoom into collapsed block" : "Zoom into block")
        }
    }
}

struct StatusIcon: View {
    let status: TaskStatus

    var body: some View {
        TaskMark(status: status)
            .foregroundColor(color)
            .scaleEffect(status == .done ? 1.04 : 1.0)
            .animation(Motion.pop, value: status)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .todo, .later, .canceled: return Theme.textTertiary
        case .doing: return Theme.inProgress
        case .done: return Theme.done
        }
    }

    private var label: String {
        switch status {
        case .todo: return "To do"
        case .doing: return "In progress"
        case .later: return "Later"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }
}

private struct ZoomTrailView: View {
    @ObservedObject var controller: OutlinerController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(ZoomTrail.items(controller.breadcrumb, maxVisible: 4).enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    ChevronIcon(expanded: false)
                        .foregroundColor(Theme.bullet)
                        .frame(width: 14)
                }
                switch item {
                case let .crumb(crumb):
                    TrailButton(label: crumb.label) { controller.zoomOut(to: crumb) }
                case let .hidden(crumbs):
                    Menu {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                            Button(crumb.label) { controller.zoomOut(to: crumb) }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .font(Typography.ui(13))
        .padding(.leading, -6)
    }
}

private struct TrailButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct JournalHeading: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.bottom, 40)
            Button(action: action) {
                Text(title)
                    .font(Typography.ui(22, .semibold))
                    .tracking(-0.3)
                    .foregroundColor(isHovered ? Theme.textStrong : Theme.textPrimary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHovered = $0 }
            .help("Open \(title)")
            .padding(.bottom, 16)
        }
        .padding(.top, 40)
    }
}

private struct JournalTitleButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(28, .semibold))
                .tracking(-0.4)
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textStrong)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(title)")
    }
}
