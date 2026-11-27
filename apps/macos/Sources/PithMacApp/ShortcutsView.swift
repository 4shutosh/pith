import PithMacCore
import SwiftUI

private enum ShortcutFilterTab: Equatable, Hashable {
    case all
    case category(ShortcutCategory)
    case builtIn

    var label: String {
        switch self {
        case .all: return "All"
        case let .category(cat):
            switch cat {
            case .navigation: return "Navigation"
            case .page: return "Page"
            case .editing: return "Editing"
            case .selection: return "Selection"
            case .window: return "Window"
            }
        case .builtIn: return "Built-in"
        }
    }
}

struct ShortcutsView: View {
    @ObservedObject var shortcuts: ShortcutStore
    let contentLeading: CGFloat
    let contentWidth: CGFloat

    @State private var filterText: String = ""
    @State private var selectedTab: ShortcutFilterTab = .all
    @State private var selectedAction: AppAction? = nil
    @State private var recordingAction: AppAction? = nil
    @State private var pendingConflict: (action: AppAction, combo: KeyCombo, conflicts: [AppAction])? = nil
    @State private var bindingProblem: (action: AppAction, combo: KeyCombo, problem: BindingProblem)? = nil
    @FocusState private var filterFocused: Bool
    @Namespace private var tabNamespace

    private struct Essential: Identifiable {
        let action: AppAction
        let hint: String
        var id: String { action.rawValue }
    }

    private static let essentials: [Essential] = [
        Essential(action: .openPalette, hint: "Jump to any page or command"),
        Essential(action: .findInPage, hint: "Search across all blocks"),
        Essential(action: .openJournals, hint: "Return to today's notes"),
        Essential(action: .openAllPages, hint: "Browse & filter your graph"),
    ]

    private func fitsTwoColumns(minimum: CGFloat) -> Bool {
        AdaptiveColumns.count(width: contentWidth, minimumColumnWidth: minimum, spacing: 16, maximum: 2) == 2
    }

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedCategory: ShortcutCategory? {
        if case let .category(cat) = selectedTab { return cat }
        return nil
    }

    private var visibleActions: [AppAction] {
        guard selectedTab != .builtIn else { return [] }
        return shortcuts.actions(in: selectedCategory, matching: filterText)
    }

    private var groupedActions: [(category: ShortcutCategory, actions: [AppAction])] {
        ShortcutCategory.allCases.compactMap { category in
            let items = visibleActions.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    private var builtInGroups: [(context: BuiltInContext, keys: [BuiltInKey])] {
        guard selectedTab == .all || selectedTab == .builtIn else { return [] }
        let matches = BuiltInKey.matching(filterText)
        return BuiltInContext.allCases.compactMap { context in
            let keys = matches.filter { $0.context == context }
            return keys.isEmpty ? nil : (context, keys)
        }
    }

    private var useTwoColumnGrid: Bool {
        selectedTab == .all && !isFiltering && fitsTwoColumns(minimum: 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pinned {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 20)
                    controlsBar
                        .padding(.bottom, 16)
                    notices
                }
                .padding(.top, 32)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    pinned {
                        contentBody
                            .padding(.top, 20)
                            .padding(.bottom, 120)
                    }
                }
                .onChange(of: selectedAction) { action in
                    if let action {
                        withAnimation(Motion.fast) {
                            proxy.scrollTo(action, anchor: .center)
                        }
                    }
                }
            }
        }
        .animation(Motion.fast, value: pendingConflict != nil)
        .animation(Motion.fast, value: bindingProblem != nil)
        .animation(Motion.fast, value: recordingAction)
        .keyScope(.screen) { handleScreenKey($0) }
        .background {
            if let target = recordingAction {
                Color.clear
                    .keyScope(.overlay, whileEditingText: true) { stroke in
                        handleRecordedKey(stroke, for: target)
                    }
            }
        }
    }

    private func pinned<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, contentLeading)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let conflict = pendingConflict {
            ConflictBanner(
                action: conflict.action,
                combo: conflict.combo,
                conflicts: conflict.conflicts,
                onReplace: {
                    shortcuts.set(conflict.combo, for: conflict.action, clearConflicts: true)
                    pendingConflict = nil
                    recordingAction = nil
                },
                onCancel: {
                    pendingConflict = nil
                }
            )
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let problem = bindingProblem {
            Text(Self.message(for: problem.problem, combo: problem.combo))
                .font(Typography.ui(TypeScale.meta))
                .foregroundColor(Theme.danger)
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }

    static func message(for problem: BindingProblem, combo: KeyCombo) -> String {
        switch problem {
        case .needsModifier:
            return "Shortcuts need ⌘, ⌃ or ⌥ so they never interrupt typing."
        case let .reservedBySystem(name):
            return "\(combo.displayString) is reserved for \(name)."
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if groupedActions.isEmpty && builtInGroups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No shortcuts match “\(filterText)”")
                    .font(Typography.ui(TypeScale.listRow, .medium))
                    .foregroundColor(Theme.textSecondary)
                Text("Try searching by action name, workflow (e.g. fold, star, bold), or key.")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if selectedTab == .all && !isFiltering {
                    essentialsStrip
                }

                if useTwoColumnGrid {
                    twoColumnCategoryCards
                } else if !groupedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedActions, id: \.category.id) { group in
                            categoryCard(category: group.category, actions: group.actions)
                        }
                    }
                }

                if !builtInGroups.isEmpty {
                    BuiltInKeysSection(groups: builtInGroups, width: contentWidth)
                }
            }
        }
    }

    private var essentialsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Essentials")
            AdaptiveGrid(items: Self.essentials, width: contentWidth, minimumColumnWidth: 280) { item in
                EssentialCard(
                    action: item.action,
                    hint: item.hint,
                    combo: shortcuts.combo(for: item.action),
                    isCustomized: shortcuts.isCustomized(item.action),
                    isRecording: recordingAction == item.action
                ) {
                    startRecording(item.action)
                }
            }
        }
    }

    private var twoColumnCategoryCards: some View {
        let leftCategories: [ShortcutCategory] = [.navigation, .page, .window]
        let rightCategories: [ShortcutCategory] = [.editing, .selection]

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(leftCategories) { category in
                    if let group = groupedActions.first(where: { $0.category == category }) {
                        categoryCard(category: group.category, actions: group.actions)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(rightCategories) { category in
                    if let group = groupedActions.first(where: { $0.category == category }) {
                        categoryCard(category: group.category, actions: group.actions)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func categoryCard(category: ShortcutCategory, actions: [AppAction]) -> some View {
        Card(title: category.title, count: actions.count) {
            VStack(spacing: 1) {
                ForEach(actions) { action in
                    ShortcutRow(
                        action: action,
                        combo: shortcuts.combo(for: action),
                        isCustomized: shortcuts.isCustomized(action),
                        isSelected: selectedAction == action,
                        isRecording: recordingAction == action,
                        onStartRecording: { startRecording(action) },
                        onReset: { shortcuts.reset(action) }
                    )
                    .id(action)
                }
            }
            .padding(6)
        }
    }

    private func startRecording(_ action: AppAction) {
        selectedAction = action
        pendingConflict = nil
        bindingProblem = nil
        recordingAction = (recordingAction == action) ? nil : action
    }

    private var header: some View {
        ScreenHeader(title: "Keyboard shortcuts") {
            HStack(spacing: 6) {
                Text("\(AppAction.allCases.count) customizable")
                Text("·")
                Text("\(BuiltInKey.all.count) built-in")
                if shortcuts.hasAnyCustomizations {
                    Text("·")
                    Text("\(shortcuts.customizedCount) customized")
                        .foregroundColor(Theme.accent)
                        .contentTransition(.numericText())
                }
            }
        } trailing: {
            if shortcuts.hasAnyCustomizations {
                SecondaryButton(title: "Reset all") {
                    shortcuts.resetAll()
                    pendingConflict = nil
                    bindingProblem = nil
                    recordingAction = nil
                }
                .transition(.opacity)
            }
        }
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchField(placeholder: "Search shortcuts, workflows, or keys…", text: $filterText, isFocused: $filterFocused)

            ChipRow {
                FilterChip(
                    title: ShortcutFilterTab.all.label,
                    count: nil,
                    isSelected: selectedTab == .all,
                    namespace: tabNamespace,
                    selectionId: "shortcutCategoryTab"
                ) {
                    withAnimation(Motion.morph) { selectedTab = .all }
                }
                ForEach(ShortcutCategory.allCases) { category in
                    FilterChip(
                        title: ShortcutFilterTab.category(category).label,
                        count: shortcuts.actions(in: category, matching: filterText).count,
                        isSelected: selectedTab == .category(category),
                        namespace: tabNamespace,
                        selectionId: "shortcutCategoryTab"
                    ) {
                        withAnimation(Motion.morph) { selectedTab = .category(category) }
                    }
                }
                FilterChip(
                    title: ShortcutFilterTab.builtIn.label,
                    count: BuiltInKey.matching(filterText).count,
                    isSelected: selectedTab == .builtIn,
                    namespace: tabNamespace,
                    selectionId: "shortcutCategoryTab"
                ) {
                    withAnimation(Motion.morph) { selectedTab = .builtIn }
                }
            }
        }
    }

    private func handleScreenKey(_ stroke: KeyStroke) -> Bool {
        let items = visibleActions
        switch (stroke.key, stroke.modifiers) {
        case (.down, []):
            guard !items.isEmpty else { return false }
            if let current = selectedAction, let idx = items.firstIndex(of: current) {
                selectedAction = items[min(idx + 1, items.count - 1)]
            } else {
                selectedAction = items.first
            }
            return true
        case (.up, []):
            guard !items.isEmpty else { return false }
            if let current = selectedAction, let idx = items.firstIndex(of: current) {
                selectedAction = items[max(idx - 1, 0)]
            } else {
                selectedAction = items.last
            }
            return true
        case (.returnKey, []):
            guard let target = selectedAction ?? items.first else { return false }
            selectedAction = target
            pendingConflict = nil
            bindingProblem = nil
            recordingAction = target
            return true
        case (.escape, []):
            if pendingConflict != nil {
                pendingConflict = nil
                return true
            }
            if bindingProblem != nil {
                bindingProblem = nil
                return true
            }
            if !filterText.isEmpty {
                filterText = ""
                return true
            }
            if selectedAction != nil {
                selectedAction = nil
                return true
            }
            return false
        default:
            return false
        }
    }

    private func handleRecordedKey(_ stroke: KeyStroke, for action: AppAction) -> Bool {
        switch shortcuts.record(stroke, for: action) {
        case .cancelled, .cleared, .bound:
            recordingAction = nil
            pendingConflict = nil
            bindingProblem = nil
        case .ignored:
            break
        case let .rejected(combo, problem):
            bindingProblem = (action: action, combo: combo, problem: problem)
        case let .conflict(combo, conflicts):
            bindingProblem = nil
            pendingConflict = (action: action, combo: combo, conflicts: conflicts)
            recordingAction = nil
        }
        return true
    }
}

private struct EssentialCard: View {
    let action: AppAction
    let hint: String
    let combo: KeyCombo?
    let isCustomized: Bool
    let isRecording: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(Typography.ui(TypeScale.ui, .semibold))
                        .foregroundColor(Theme.textStrong)
                        .lineLimit(1)
                    Text(isRecording ? "Press new shortcut…" : hint)
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(isRecording ? Theme.accent : Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let combo {
                    KeycapRow(caps: combo.keycaps, tint: isCustomized ? Theme.accent : Theme.textSecondary)
                } else {
                    Text("Unbound")
                        .font(Typography.ui(TypeScale.label))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered || isRecording ? Theme.hover : Theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecording ? Theme.accent : (isHovered ? Theme.elevatedBorder : Theme.divider), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle(scale: 0.99))
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct ShortcutRow: View {
    let action: AppAction
    let combo: KeyCombo?
    let isCustomized: Bool
    let isSelected: Bool
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onReset: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(action.title)
                    .font(Typography.ui(TypeScale.ui, isSelected || isRecording ? .medium : .regular))
                    .foregroundColor(isSelected || isRecording ? Theme.textStrong : Theme.textPrimary)
                    .lineLimit(1)
                if isCustomized {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                }
            }

            Spacer(minLength: 0)

            if isCustomized && (isHovered || isSelected) && !isRecording {
                Button(action: onReset) {
                    Text("Reset")
                        .font(Typography.ui(TypeScale.label, .medium))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
                }
                .buttonStyle(PressButtonStyle(scale: 0.96))
                .cursor(.pointingHand)
                .transition(.opacity)
            } else if !isCustomized && isHovered && !isRecording {
                Text("Edit")
                    .font(Typography.ui(TypeScale.label))
                    .foregroundColor(Theme.textTertiary)
                    .transition(.opacity)
            }

            if isRecording {
                Text("Press key…")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
            } else if let combo {
                KeycapRow(caps: combo.keycaps, tint: isCustomized ? Theme.accent : Theme.textSecondary)
            } else {
                Text("Unbound")
                    .font(Typography.ui(TypeScale.label))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? Theme.selected : (isSelected ? Theme.rowSelected : (isHovered ? Theme.hover : Color.clear)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onStartRecording)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct ConflictBanner: View {
    let action: AppAction
    let combo: KeyCombo
    let conflicts: [AppAction]
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(combo.displayString) is already assigned to \(conflicts.map(\.title).joined(separator: ", ")).")
                .font(Typography.ui(TypeScale.ui))
                .foregroundColor(Theme.textPrimary)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(Typography.ui(TypeScale.meta, .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                .cursor(.pointingHand)
            Button("Replace", action: onReplace)
                .buttonStyle(PressButtonStyle(scale: 0.96))
                .font(Typography.ui(TypeScale.meta, .medium))
                .foregroundColor(Theme.textStrong)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selected))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
                .cursor(.pointingHand)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
    }
}

private struct BuiltInKeysSection: View {
    struct Group: Identifiable {
        let context: BuiltInContext
        let keys: [BuiltInKey]
        var id: String { context.id }
    }

    let groups: [(context: BuiltInContext, keys: [BuiltInKey])]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Built-in keys")
                    .font(Typography.ui(TypeScale.ui, .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Fixed outliner & editor keys")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }
            AdaptiveGrid(
                items: groups.map { Group(context: $0.context, keys: $0.keys) },
                width: width,
                minimumColumnWidth: 320,
                spacing: 16
            ) { group in
                Card(title: group.context.title) {
                    VStack(spacing: 1) {
                        ForEach(group.keys) { key in
                            HStack(spacing: 10) {
                                Text(key.title)
                                    .font(Typography.ui(TypeScale.meta))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                KeycapRow(caps: key.keycaps, tint: Theme.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

