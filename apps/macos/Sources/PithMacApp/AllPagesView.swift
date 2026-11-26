import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct PageListView: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool
    let contentLeading: CGFloat
    let contentWidth: CGFloat

    @State private var tab: PageDirectoryTab = .pages
    @State private var sort: PageDirectorySort = .updated
    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var renamingPageId: String?
    @State private var renameDraft: String = ""
    @State private var keyMonitor: Any?
    @FocusState private var filterFocused: Bool

    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var summaries: [FfiPageSummary] {
        PageDirectory.filter(controller.pageSummaries, tab: tab, query: query, sort: sort)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var offersCreate: Bool {
        PageDirectory.offersCreate(query: query, in: controller.pageSummaries)
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

                        if summaries.isEmpty && !offersCreate {
                            emptyState
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(summaries.enumerated()), id: \.element.page.id) { index, summary in
                                    let isRenaming = renamingPageId == summary.page.id
                                    PageDirectoryRow(
                                        summary: summary,
                                        updated: updatedLabel(summary.page),
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
                                            ? { controller.deletePage(summary.page.id) }
                                            : nil
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
                    .padding(.top, 52)
                    .padding(.bottom, 100)
                    Spacer(minLength: 0)
                }
            }
            .onChange(of: highlightedIndex) { idx in
                if summaries.indices.contains(idx) {
                    proxy.scrollTo(summaries[idx].page.id)
                }
            }
        }
        .onChange(of: query) { _ in highlightedIndex = 0 }
        .onChange(of: tab) { _ in highlightedIndex = 0 }
        .onChange(of: sort) { _ in highlightedIndex = 0 }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("All pages")
                .font(Typography.ui(TypeScale.pageTitle, .semibold))
                .tracking(-0.4)
                .foregroundColor(Theme.textStrong)

            Spacer()

            HStack(spacing: 7) {
                SearchIcon(size: 12)
                    .foregroundColor(Theme.textTertiary)
                TextField("Filter pages…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(TypeScale.ui))
                    .foregroundColor(Theme.textStrong)
                    .focused($filterFocused)
                    .onSubmit { openHighlightedOrCreate() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Text("×")
                            .font(Typography.ui(13))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 210, height: 27)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))

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
            .buttonStyle(.plain)
            .help("Create or open page (⌘K)")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(PageDirectoryTab.allCases, id: \.self) { option in
                let count = PageDirectory.count(in: controller.pageSummaries, for: option)
                FilterChip(
                    title: option.rawValue,
                    count: count,
                    isSelected: tab == option
                ) {
                    tab = option
                }
            }

            Spacer()

            Menu {
                ForEach(PageDirectorySort.allCases, id: \.self) { option in
                    Button {
                        sort = option
                    } label: {
                        if sort == option {
                            Text("✓ \(option.rawValue)")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sort.rawValue)
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textSecondary)
                    ChevronIcon(expanded: true)
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover.opacity(0.6)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("TITLE")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("LINKS")
                .frame(width: 54, alignment: .trailing)
            Text("BLOCKS")
                .frame(width: 58, alignment: .trailing)
            Text("UPDATED")
                .frame(width: 72, alignment: .trailing)
            Spacer().frame(width: 48)
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
        if list.indices.contains(highlightedIndex) {
            controller.selectPage(list[highlightedIndex].page.id)
        } else if offersCreate {
            controller.openPageByTitle(trimmedQuery)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow?.attachedSheet == nil, renamingPageId == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let arrowFlags = flags.subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers

        if key == "/", flags.isEmpty, !filterFocused {
            filterFocused = true
            return true
        }
        if event.keyCode == 53, filterFocused {
            if !query.isEmpty {
                query = ""
            } else {
                filterFocused = false
            }
            return true
        }
        let count = summaries.count
        switch (event.keyCode, arrowFlags) {
        case (126, []):
            guard count > 0 else { return false }
            highlightedIndex = max(0, highlightedIndex - 1)
            return true
        case (125, []):
            guard count > 0 else { return false }
            highlightedIndex = min(count - 1, highlightedIndex + 1)
            return true
        case (36, []), (76, []):
            guard !filterFocused else { return false }
            openHighlightedOrCreate()
            return true
        default:
            return false
        }
    }
}

private struct PageDirectoryRow: View {
    let summary: FfiPageSummary
    let updated: String
    let isHighlighted: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: (() -> Void)?
    @State private var isHovered = false

    private var page: FfiPage { summary.page }

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("Page title", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(TypeScale.listRow, .medium))
                    .foregroundColor(Theme.textStrong)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: 7) {
                        if page.journalDay != nil {
                            TodayIcon()
                                .foregroundColor(Theme.textTertiary)
                        }
                        Text(page.title)
                            .font(Typography.ui(TypeScale.listRow, isHovered || isHighlighted ? .medium : .regular))
                            .foregroundColor(
                                summary.blockCount == 0
                                    ? Theme.textSecondary
                                    : (isHovered || isHighlighted ? Theme.textStrong : Theme.textPrimary)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(summary.backlinkCount == 0 ? "–" : "\(summary.backlinkCount)")
                .font(Typography.ui(12).monospacedDigit())
                .foregroundColor(summary.backlinkCount > 0 ? Theme.accent : Theme.textTertiary.opacity(0.6))
                .frame(width: 54, alignment: .trailing)

            Text(summary.blockCount == 0 ? "–" : "\(summary.blockCount)")
                .font(Typography.ui(12).monospacedDigit())
                .foregroundColor(summary.blockCount > 0 ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                .frame(width: 58, alignment: .trailing)

            Text(updated)
                .font(Typography.ui(12).monospacedDigit())
                .foregroundColor(Theme.textTertiary)
                .frame(width: 72, alignment: .trailing)

            HStack(spacing: 2) {
                Button(action: onToggleFavorite) {
                    StarIcon(filled: page.favorite)
                        .foregroundColor(page.favorite ? Theme.accent : Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(page.favorite || isHovered ? 1 : 0)
                .help(page.favorite ? "Remove from Favorites" : "Add to Favorites")

                if onDelete != nil {
                    Menu {
                        Button("Rename", action: onBeginRename)
                        Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
                        if let onDelete {
                            Divider()
                            Button("Delete Page", role: .destructive, action: onDelete)
                        }
                    } label: {
                        Text("···")
                            .font(Typography.ui(12, .semibold))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(isHovered ? 1 : 0)
                } else {
                    Spacer().frame(width: 22)
                }
            }
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Theme.hover : (isHighlighted ? Theme.selected.opacity(0.65) : Color.clear))
        )
        .padding(.horizontal, -10)
        .onHover { isHovered = $0 }
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

private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Typography.ui(12, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                Text("\(count)")
                    .font(Typography.ui(11).monospacedDigit())
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.selected : (isHovered ? Theme.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
        .onHover { isHovered = $0 }
    }
}
