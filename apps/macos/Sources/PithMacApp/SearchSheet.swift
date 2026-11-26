import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct QuickSearchSheet: View {
    @ObservedObject var controller: OutlinerController
    @Binding var isPresented: Bool
    let onCommand: (PaletteCommand) -> Void
    @State private var query: String = ""
    @State private var selected: Int = 0
    @State private var keyMonitor: Any?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pageHits: [FfiSearchHit] {
        controller.searchHits.filter { if case .page = $0 { return true } else { return false } }
    }

    private var blockHits: [FfiSearchHit] {
        controller.searchHits.filter { if case .block = $0 { return true } else { return false } }
    }

    private var orderedHits: [FfiSearchHit] {
        pageHits + blockHits
    }

    private var commands: [PaletteItem] {
        let matches = controller.paletteItems(matching: trimmedQuery)
        return trimmedQuery.isEmpty ? matches : Array(matches.prefix(5))
    }

    private var offersCreate: Bool {
        SearchPresentation.offersCreatePage(query: query, hits: controller.searchHits)
    }

    private var choiceCount: Int {
        commands.count + orderedHits.count + (offersCreate ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SearchIcon(size: 15)
                    .foregroundColor(Theme.textTertiary)
                TextField("Search, create a page, or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(17))
                    .foregroundColor(Theme.textStrong)
                    .onChange(of: query) {
                        controller.runSearch($0)
                        selected = 0
                    }
                    .onSubmit(openSelected)
                if !controller.searchHits.isEmpty {
                    Text("\(controller.searchHits.count) results")
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !commands.isEmpty {
                            GroupLabel(title: "Commands")
                            ForEach(Array(commands.enumerated()), id: \.offset) { index, item in
                                CommandRow(item: item, isSelected: selected == index) { run(item) }
                                    .id(index)
                            }
                        }
                        if !pageHits.isEmpty {
                            GroupLabel(title: "Pages")
                            ForEach(Array(pageHits.enumerated()), id: \.offset) { index, hit in
                                let position = commands.count + index
                                HitRow(hit: hit, isSelected: selected == position) { open(hit) }
                                    .id(position)
                            }
                        }
                        if !blockHits.isEmpty {
                            GroupLabel(title: "Blocks")
                            ForEach(Array(blockHits.enumerated()), id: \.offset) { index, hit in
                                let position = commands.count + pageHits.count + index
                                HitRow(hit: hit, isSelected: selected == position) { open(hit) }
                                    .id(position)
                            }
                        }
                        if offersCreate {
                            let position = commands.count + orderedHits.count
                            CreatePageRow(title: trimmedQuery, isSelected: selected == position, action: createPage)
                                .id(position)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { proxy.scrollTo($0) }
            }

            HStack(spacing: 18) {
                KeyHint(keys: "↑↓", label: "Move")
                KeyHint(keys: "↵", label: "Open")
                KeyHint(keys: "esc", label: "Close")
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
        .frame(width: 680, height: 500)
        .background(Theme.elevated)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:
                moveSelection(1)
                return nil
            case 126:
                moveSelection(-1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func moveSelection(_ delta: Int) {
        guard choiceCount > 0 else { return }
        selected = (selected + delta + choiceCount) % choiceCount
    }

    private func open(_ hit: FfiSearchHit) {
        controller.openSearchHit(hit)
        isPresented = false
    }

    private func openSelected() {
        let hitIndex = selected - commands.count
        if commands.indices.contains(selected) {
            run(commands[selected])
        } else if orderedHits.indices.contains(hitIndex) {
            open(orderedHits[hitIndex])
        } else if !trimmedQuery.isEmpty {
            createPage()
        }
    }

    private func run(_ item: PaletteItem) {
        isPresented = false
        onCommand(item.command)
    }

    private func createPage() {
        controller.openPageByTitle(trimmedQuery)
        isPresented = false
    }
}

private struct GroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(12, .medium))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct HitRow: View {
    let hit: FfiSearchHit
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                icon.frame(width: 16, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    switch hit {
                    case let .page(_, _, highlightedTitle):
                        Text(SearchPresentation.highlighted(highlightedTitle))
                            .font(Typography.ui(14, .medium))
                            .foregroundColor(Theme.textStrong)
                    case let .block(_, _, _, breadcrumb, snippet, _, _):
                        Text(SearchPresentation.breadcrumb(breadcrumb))
                            .font(Typography.ui(12))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                        Text(SearchPresentation.highlighted(snippet))
                            .font(Typography.ui(14))
                            .foregroundColor(Theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected || isHovered ? Theme.rowSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch hit {
        case .page:
            Circle()
                .fill(isSelected || isHovered ? Theme.accent : Theme.bullet)
                .frame(width: 5, height: 5)
                .padding(.top, 7)
        case .block:
            Circle()
                .stroke(Theme.bullet, lineWidth: 1.2)
                .frame(width: 5.5, height: 5.5)
                .padding(.top, 20)
        }
    }
}

private struct CreatePageRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlusIcon()
                    .foregroundColor(Theme.accent)
                    .frame(width: 16)
                Text("Create page")
                    .font(Typography.ui(14, .medium))
                    .foregroundColor(Theme.textStrong)
                Text("“\(title)”")
                    .font(Typography.ui(14))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected || isHovered ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(Typography.ui(11))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 5)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.elevatedBorder, lineWidth: 1))
            Text(label)
                .font(Typography.ui(12))
                .foregroundColor(Theme.textTertiary)
        }
    }
}

private struct CommandRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(item.title)
                    .font(Typography.ui(TypeScale.listRow))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected || isHovered ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}
