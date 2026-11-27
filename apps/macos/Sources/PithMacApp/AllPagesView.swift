import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct PageListView: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var directory: PageDirectoryModel
    @Binding var showSearch: Bool
    let contentLeading: CGFloat
    let contentWidth: CGFloat

    @State private var tab: PageDirectoryTab = .pages
    @State private var sort: PageDirectorySort = .updated
    @State private var query: String = ""
    @State private var highlightedIndex: Int?
    @State private var renamingPageId: String?
    @State private var renameDraft: String = ""
    @FocusState private var filterFocused: Bool
    @Namespace private var tabNamespace

    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @State private var summaries: [FfiPageSummary] = []
    @State private var offersCreate = false
    @State private var counts: [PageDirectoryTab: Int] = [:]

    private func refreshVisible(_ all: [FfiPageSummary]) {
        summaries = PageDirectory.filter(all, tab: tab, query: query, sort: sort)
        offersCreate = PageDirectory.offersCreate(query: query, in: all)
    }

    private func refreshCounts(_ all: [FfiPageSummary]) {
        counts = Dictionary(uniqueKeysWithValues: PageDirectoryTab.allCases.map { ($0, PageDirectory.count(in: all, for: $0)) })
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        toolbar
                            .padding(.top, 16)
                            .padding(.bottom, 12)

                        columnHeader
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 1)

                        if summaries.isEmpty && !offersCreate && directory.isLoaded {
                            emptyState
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(summaries.enumerated()), id: \.element.page.id) { index, summary in
                                    let isRenaming = renamingPageId == summary.page.id
                                    PageDirectoryRow(
                                        summary: summary,
                                        updated: updatedLabel(summary.page),
                                        layout: layout,
                                        isHighlighted: index == highlightedIndex && !isRenaming,
                                        isRenaming: isRenaming,
                                        renameDraft: $renameDraft,
                                        onOpen: { controller.selectPage(summary.page.id) },
                                        onToggleFavorite: { controller.toggleFavorite(summary.page.id) },
                                        onBeginRename: {
                                            renamingPageId = summary.page.id
                                            renameDraft = summary.page.title
                                        },
                                        onCommitRename: {
                                            controller.renamePage(summary.page.id, to: renameDraft)
                                            renamingPageId = nil
                                        },
                                        onCancelRename: { renamingPageId = nil },
                                        onDelete: summary.page.journalDay == nil
                                            ? { controller.requestDelete(summary.page.id) }
                                            : nil,
                                        onHover: { inside in
                                            if inside {
                                                highlightedIndex = index
                                            } else if highlightedIndex == index {
                                                highlightedIndex = nil
                                            }
                                        }
                                    )
                                    .id(summary.page.id)
                                }

                                if offersCreate {
                                    CreateInlineRow(title: trimmedQuery) {
                                        controller.openPageByTitle(trimmedQuery)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.leading, contentLeading)
                    .padding(.top, 26)
                    .padding(.bottom, 100)
                    Spacer(minLength: 0)
                }
            }
            .onChange(of: highlightedIndex) { idx in
                if let idx, summaries.indices.contains(idx) {
                    proxy.scrollTo(summaries[idx].page.id)
                }
            }
        }
        .onChange(of: query) { _ in
            highlightedIndex = nil
            refreshVisible(PageDirectory.merge(controller.library, counts: directory.summaries))
        }
        .onChange(of: tab) { _ in
            highlightedIndex = nil
            refreshVisible(PageDirectory.merge(controller.library, counts: directory.summaries))
        }
        .onChange(of: sort) { _ in
            highlightedIndex = nil
            refreshVisible(PageDirectory.merge(controller.library, counts: directory.summaries))
        }
        .onReceive(directory.$summaries) { counts in
            let all = PageDirectory.merge(controller.library, counts: counts)
            refreshCounts(all)
            refreshVisible(all)
        }
        .onReceive(controller.$library) { library in
            let all = PageDirectory.merge(library, counts: directory.summaries)
            refreshCounts(all)
            refreshVisible(all)
        }
        .keyScope(.screen, whileEditingText: true) { handleKey($0) }
    }

    private var layout: PageDirectoryLayout {
        PageDirectoryLayout(width: contentWidth)
    }

    @ViewBuilder
    private var header: some View {
        if layout.stacksHeader {
            VStack(alignment: .leading, spacing: 14) {
                pageTitle
                HStack(spacing: 8) {
                    filterField
                        .frame(maxWidth: .infinity)
                    newButton
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                pageTitle
                Spacer()
                filterField
                    .frame(width: 210)
                newButton
            }
        }
    }

    private var pageTitle: some View {
        ScreenTitle(title: "All pages")
    }

    private var filterField: some View {
        SearchField(
            placeholder: "Filter pages…",
            text: $query,
            isFocused: $filterFocused,
            shortcutHint: "/",
            onSubmit: openHighlightedOrCreate
        )
        .help("Filter pages (/)")
    }

    private var newButton: some View {
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 4) {
                    PlusIcon()
                    Text("New")
                        .font(Typography.ui(12, .medium))
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selected))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .cursor(.pointingHand)
            .help("Create or open page (⌘K)")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ChipRow {
                ForEach(PageDirectoryTab.allCases, id: \.self) { option in
                    FilterChip(
                        title: option.rawValue,
                        count: counts[option] ?? 0,
                        isSelected: tab == option,
                        namespace: tabNamespace,
                        selectionId: "pageFilterTab"
                    ) {
                        withAnimation(Motion.morph) {
                            tab = option
                        }
                    }
                }
            }
            SortPicker(sort: $sort, compact: layout.compactSort)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("TITLE")
                .frame(maxWidth: .infinity, alignment: .leading)
            if layout.showsCounts {
                Text("LINKS")
                    .frame(width: 54, alignment: .trailing)
                Text("BLOCKS")
                    .frame(width: 58, alignment: .trailing)
            }
            if layout.updatedInColumn {
                Text("UPDATED")
                    .frame(width: 72, alignment: .trailing)
            }
            Spacer().frame(width: 28)
        }
        .font(Typography.ui(TypeScale.label, .medium))
        .tracking(0.5)
        .foregroundColor(Theme.textTertiary)
        .frame(height: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(tab == .empty ? "No empty pages" : "No matching pages")
                .font(Typography.ui(13, .medium))
                .foregroundColor(Theme.textSecondary)
            if tab == .favorites {
                Text("Star a page to pin it to your favorites.")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
            } else if !trimmedQuery.isEmpty {
                Text("Press Return to create “\(trimmedQuery)”.")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func updatedLabel(_ page: FfiPage) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(page.updatedAt) / 1000)
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func openHighlightedOrCreate() {
        let list = summaries
        if let index = highlightedIndex, list.indices.contains(index) {
            controller.selectPage(list[index].page.id)
        } else if let first = list.first {
            controller.selectPage(first.page.id)
        } else if offersCreate {
            controller.openPageByTitle(trimmedQuery)
        }
    }

    private func handleKey(_ stroke: KeyStroke) -> Bool {
        guard renamingPageId == nil else { return false }
        let list = summaries

        switch (stroke.key, stroke.modifiers) {
        case (.character("/"), []) where !filterFocused:
            filterFocused = true
        case (.escape, []) where filterFocused:
            if query.isEmpty {
                filterFocused = false
            } else {
                query = ""
            }
        case (.escape, []) where highlightedIndex != nil:
            highlightedIndex = nil
        case (.up, []) where !list.isEmpty:
            highlightedIndex = max(0, (highlightedIndex ?? list.count) - 1)
        case (.down, []) where !list.isEmpty:
            highlightedIndex = min(list.count - 1, (highlightedIndex ?? -1) + 1)
        case (.returnKey, []) where !filterFocused:
            openHighlightedOrCreate()
        default:
            return handleRowKey(stroke, in: list)
        }
        return true
    }

    private func handleRowKey(_ stroke: KeyStroke, in list: [FfiPageSummary]) -> Bool {
        guard !filterFocused, let index = highlightedIndex, list.indices.contains(index) else { return false }
        let page = list[index].page
        switch (stroke.key, stroke.modifiers) {
        case (.character("s"), []):
            controller.toggleFavorite(page.id)
        case (.character("r"), []) where page.journalDay == nil:
            renamingPageId = page.id
            renameDraft = page.title
        case (.backspace, .command) where page.journalDay == nil,
             (.forwardDelete, .command) where page.journalDay == nil:
            controller.requestDelete(page.id)
        default:
            return false
        }
        return true
    }
}

private struct PageDirectoryRow: View {
    let summary: FfiPageSummary
    let updated: String
    let layout: PageDirectoryLayout
    let isHighlighted: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: (() -> Void)?
    let onHover: (Bool) -> Void
    @FocusState private var renameFocused: Bool

    private var page: FfiPage { summary.page }

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("Page title", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(TypeScale.listRow, .medium))
                    .foregroundColor(Theme.textStrong)
                    .focused($renameFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .onAppear {
                        DispatchQueue.main.async { renameFocused = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: 7) {
                        if page.journalDay != nil {
                            TodayIcon()
                                .foregroundColor(Theme.textTertiary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(page.title)
                                .font(Typography.ui(TypeScale.listRow, isHighlighted ? .medium : .regular))
                                .foregroundColor(
                                    summary.blockCount == 0
                                        ? Theme.textSecondary
                                        : (isHighlighted ? Theme.textStrong : Theme.textPrimary)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !layout.updatedInColumn {
                                Text(updated)
                                    .font(Typography.ui(TypeScale.label))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        if summary.blockCount == 0 && page.journalDay == nil {
                            Text("empty")
                                .font(Typography.ui(TypeScale.label))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.elevated))
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if layout.showsCounts {
                Text(summary.backlinkCount == 0 ? "–" : "\(summary.backlinkCount)")
                    .font(Typography.ui(12).monospacedDigit())
                    .foregroundColor(summary.backlinkCount > 0 ? Theme.accent : Theme.textTertiary.opacity(0.6))
                    .frame(width: 54, alignment: .trailing)

                Text(summary.blockCount == 0 ? "–" : "\(summary.blockCount)")
                    .font(Typography.ui(12).monospacedDigit())
                    .foregroundColor(summary.blockCount > 0 ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                    .frame(width: 58, alignment: .trailing)
            }

            if layout.updatedInColumn {
                Text(updated)
                    .font(Typography.ui(12).monospacedDigit())
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 72, alignment: .trailing)
            }

            HStack(spacing: 2) {
                Button(action: onToggleFavorite) {
                    StarIcon(filled: page.favorite)
                        .foregroundColor(page.favorite ? Theme.accent : Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .opacity(page.favorite || isHighlighted ? 1 : 0)
                .help(page.favorite ? "Remove from Favorites" : "Add to Favorites")

            }
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: layout.updatedInColumn ? 31 : 44)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Theme.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, -10)
        .onHover(perform: onHover)
        .contextMenu {
            Button("Open", action: onOpen)
            Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            if let onDelete {
                Button("Rename", action: onBeginRename)
                Divider()
                Button("Delete Page", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct CreateInlineRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PlusIcon()
                    .foregroundColor(Theme.accent)
                Text("Create page “\(title)”")
                    .font(Typography.ui(13, .medium))
                    .foregroundColor(Theme.textStrong)
                Spacer()
                Text("↵")
                    .font(Typography.ui(11))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : Theme.elevated))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

private struct SortPicker: View {
    @Binding var sort: PageDirectorySort
    let compact: Bool
    @State private var isOpen = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                if !compact {
                    Text("Sort")
                        .foregroundColor(Theme.textTertiary)
                }
                Text(sort.rawValue)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.textPrimary)
                ChevronIcon(expanded: true)
                    .foregroundColor(Theme.textTertiary)
            }
            .font(Typography.ui(TypeScale.meta))
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOpen || isHovered ? Theme.hover : Theme.elevated)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.elevatedBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .help("Change sort order")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(PageDirectorySort.allCases, id: \.self) { option in
                    SortOptionRow(title: option.rawValue, isSelected: option == sort) {
                        sort = option
                        isOpen = false
                    }
                }
            }
            .padding(5)
            .frame(width: 180)
            .background(Theme.elevated)
        }
    }
}

private struct SortOptionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                CheckIcon()
                    .foregroundColor(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                Text(title)
                    .font(Typography.ui(TypeScale.ui, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}
