import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct QuickSearchSheet: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @Binding var isPresented: Bool
    var onDismiss: () -> Void = {}
    let onCommand: (AppAction) -> Void
    @State private var query: String = ""
    @State private var selected: Int = 0
    @State private var recording: AppAction?
    @State private var problem: (combo: KeyCombo, problem: BindingProblem)?
    @State private var conflict: (combo: KeyCombo, actions: [AppAction])?
    @FocusState private var inputFocused: Bool

    private var scope: PaletteScope {
        controller.paletteScope
    }

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

    private var shortcutSections: [(category: ShortcutCategory, actions: [AppAction])] {
        shortcuts.sections(matching: trimmedQuery)
    }

    private var shortcutActions: [AppAction] {
        shortcutSections.flatMap(\.actions)
    }

    private var builtInGroups: [(context: BuiltInContext, keys: [BuiltInKey])] {
        let keys = BuiltInKey.matching(trimmedQuery)
        return BuiltInContext.allCases.compactMap { context in
            let inContext = keys.filter { $0.context == context }
            return inContext.isEmpty ? nil : (context, inContext)
        }
    }

    private var offersCreate: Bool {
        SearchPresentation.offersCreatePage(query: query, hits: controller.searchHits)
    }

    private var choiceCount: Int {
        switch scope {
        case .everything: return commands.count + orderedHits.count + (offersCreate ? 1 : 0)
        case .shortcuts: return shortcutActions.count
        }
    }

    private var selectedAction: AppAction? {
        switch scope {
        case .everything: return commands.indices.contains(selected) ? commands[selected].action : nil
        case .shortcuts: return shortcutActions.indices.contains(selected) ? shortcutActions[selected] : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    switch scope {
                    case .everything: everythingList
                    case .shortcuts: shortcutsList
                    }
                }
                .onChange(of: selected) { proxy.scrollTo($0) }
            }
            footer
        }
        .frame(width: 680, height: 500)
        .background(Theme.elevated)
        .animation(Motion.fast, value: selected)
        .animation(Motion.fast, value: recording)
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: scope) { _ in
            query = ""
            selected = 0
            stopRecording()
        }
        .keyScope(.overlay, whileEditingText: true, isActive: isPresented) { handleKey($0) }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
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
            TextField(scope == .shortcuts ? "Search shortcuts" : "Search, create a page, or run a command", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.ui(17))
                .foregroundColor(Theme.textStrong)
                .focused($inputFocused)
                .onChange(of: query) {
                    if scope == .everything {
                        controller.runSearch($0)
                    }
                    selected = 0
                }
                .onSubmit(openSelected)
            if scope == .everything && !controller.searchHits.isEmpty {
                Text("\(controller.searchHits.count) results")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var everythingList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !commands.isEmpty {
                GroupLabel(title: "Commands")
                ForEach(Array(commands.enumerated()), id: \.offset) { index, item in
                    CommandRow(
                        title: item.title,
                        keycaps: shortcuts.keycaps(for: item.action),
                        isCustomized: shortcuts.isCustomized(item.action),
                        isSelected: selected == index,
                        isRecording: recording == item.action
                    ) { run(item) }
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

    private var shortcutsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shortcutSections, id: \.category) { section in
                GroupLabel(title: section.category.title)
                ForEach(section.actions) { action in
                    let position = shortcutActions.firstIndex(of: action) ?? 0
                    CommandRow(
                        title: action.title,
                        keycaps: shortcuts.keycaps(for: action),
                        isCustomized: shortcuts.isCustomized(action),
                        isSelected: selected == position,
                        isRecording: recording == action
                    ) {
                        selected = position
                        startRecording(action)
                    }
                    .id(position)
                }
            }
            ForEach(builtInGroups, id: \.context) { group in
                GroupLabel(title: "Built-in · \(group.context.title)")
                ForEach(group.keys) { key in
                    CommandRow(title: key.title, keycaps: key.keycaps, isCustomized: false, isSelected: false, isRecording: false, action: nil)
                }
            }
            if shortcutSections.isEmpty && builtInGroups.isEmpty {
                Text("No shortcuts match “\(trimmedQuery)”")
                    .font(Typography.ui(TypeScale.ui))
                    .foregroundColor(Theme.textTertiary)
                    .padding(12)
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if let conflict, let recording {
                Text("\(conflict.combo.displayString) is used by \(conflict.actions.map(\.title).joined(separator: ", ")).")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(keys: "↵", label: "Replace")
                KeyHint(keys: "esc", label: "Keep \(recording.title)'s old key")
            } else if recording != nil {
                if let problem {
                    Text(ShortcutsView.message(for: problem.problem, combo: problem.combo))
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Press the new shortcut")
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                KeyHint(keys: "⌫", label: "Clear")
                KeyHint(keys: "esc", label: "Cancel")
            } else {
                KeyHint(keys: "↑↓", label: "Move")
                switch scope {
                case .everything:
                    KeyHint(keys: "↵", label: selectedAction == nil ? "Open" : "Run")
                    if selectedAction != nil {
                        KeyHint(keys: "⌘↵", label: "Change shortcut")
                    }
                case .shortcuts:
                    KeyHint(keys: "↵", label: "Change shortcut")
                    KeyHint(keys: "⌫", label: "All commands")
                }
                KeyHint(keys: "esc", label: "Close")
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
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
                controller.paletteScope = target
            }
            return true
        }
        switch (stroke.key, stroke.modifiers) {
        case (.escape, []):
            onDismiss()
        case (.returnKey, []):
            openSelected()
        case (.returnKey, [.command]):
            guard let action = selectedAction else { return true }
            startRecording(action)
        case (.backspace, []) where scope == .shortcuts && query.isEmpty:
            controller.paletteScope = .everything
        case (.down, []):
            moveSelection(1)
        case (.up, []):
            moveSelection(-1)
        default:
            return false
        }
        return true
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
        guard choiceCount > 0 else { return }
        selected = (selected + delta + choiceCount) % choiceCount
    }

    private func open(_ hit: FfiSearchHit) {
        controller.openSearchHit(hit)
        isPresented = false
    }

    private func openSelected() {
        if scope == .shortcuts {
            if let action = selectedAction {
                startRecording(action)
            }
            return
        }
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
        onCommand(item.action)
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
                HStack(spacing: 4) {
                    ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                        KeycapLabel(cap: cap, color: isCustomized ? Theme.accent : Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected || (isHovered && action != nil) ? Theme.rowSelected : Color.clear))
        .contentShape(Rectangle())
    }
}
