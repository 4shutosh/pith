import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var sidebarStore: SidebarStore = .shared
    @Binding var showSearch: Bool
    @Namespace private var selectionNamespace

    @State private var showAllFavorites = false
    @State private var isCreatingSection = false
    @State private var newSectionTitle = ""
    @State private var pendingPageForNewSection: String? = nil
    @State private var renamingSectionId: UUID? = nil
    @State private var renameDraft = ""
    @FocusState private var newSectionFocused: Bool
    @FocusState private var renameSectionFocused: Bool

    private var destination: SidebarDestination? {
        controller.sidebarDestination
    }

    private var visibleFavorites: [FfiPage] {
        let all = controller.favoritePages
        if showAllFavorites || sidebarStore.favoritesPreviewLimit <= 0 || all.count <= sidebarStore.favoritesPreviewLimit {
            return all
        }
        return Array(all.prefix(sidebarStore.favoritesPreviewLimit))
    }

    private var hiddenFavoritesCount: Int {
        max(0, controller.favoritePages.count - visibleFavorites.count)
    }

    private var recentPages: [FfiPage] {
        sidebarStore.recentPages(in: controller.library)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SearchFieldButton(shortcut: shortcuts.displayString(for: .openPalette)) {
                    withAnimation(Motion.pop) { showSearch = true }
                }
                NewSectionIconButton {
                    beginNewSection()
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 1) {
                SidebarNavItem(
                    title: "Journals",
                    shortcut: shortcuts.displayString(for: .openJournals),
                    isSelected: destination == .journals,
                    selectionNamespace: selectionNamespace
                ) {
                    TodayIcon()
                } action: {
                    controller.openTodayJournal()
                }
                SidebarNavItem(
                    title: "All pages",
                    shortcut: shortcuts.displayString(for: .openAllPages),
                    isSelected: destination == .allPages,
                    selectionNamespace: selectionNamespace
                ) {
                    PagesIcon()
                } action: {
                    controller.showAllPages()
                }
            }
            .padding(.bottom, 8)

            SectionsDivider {
                beginNewSection()
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    favoritesSection

                    ForEach(Array(sidebarStore.sections.enumerated()), id: \.element.id) { index, section in
                        customSection(section, index: index)
                    }

                    if isCreatingSection {
                        newSectionEditor
                    }

                    if sidebarStore.showRecent && !recentPages.isEmpty {
                        recentSection
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            .contextMenu {
                Button("New Section…") {
                    beginNewSection()
                }
            }

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.top, 4)
                .padding(.bottom, 8)

            VStack(spacing: 1) {
                SidebarNavItem(
                    title: "Shortcuts",
                    shortcut: shortcuts.displayString(for: .openShortcuts),
                    isSelected: destination == .shortcuts,
                    selectionNamespace: selectionNamespace
                ) {
                    KeyboardIcon()
                } action: {
                    controller.showShortcuts()
                }
                SidebarNavItem(
                    title: "Settings",
                    shortcut: shortcuts.displayString(for: .openSettings),
                    isSelected: destination == .settings,
                    selectionNamespace: selectionNamespace
                ) {
                    SettingsIcon()
                } action: {
                    controller.showSettings()
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .padding(.horizontal, SidebarMetrics.outerInset)
        .animation(Motion.morph, value: destination)
    }

    @ViewBuilder
    private var favoritesSection: some View {
        CollapsibleSectionHeader(
            title: "Favorites",
            count: controller.favoritePages.count,
            isCollapsed: sidebarStore.favoritesCollapsed,
            onToggle: {
                withAnimation(Motion.fast) {
                    sidebarStore.favoritesCollapsed.toggle()
                }
            }
        ) {
            StarIcon(filled: false)
        }

        if !sidebarStore.favoritesCollapsed {
            if controller.favoritePages.isEmpty {
                Text("Star a page to pin it here")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, SidebarMetrics.nestedInset)
                    .frame(height: 24)
            } else {
                pageList(visibleFavorites, section: nil)
                    .animation(Motion.morph, value: visibleFavorites.map(\.id))

                if hiddenFavoritesCount > 0 {
                    SidebarSubtleActionRow(title: "Show \(hiddenFavoritesCount) more", leadingInset: SidebarMetrics.nestedInset) {
                        withAnimation(Motion.fast) { showAllFavorites = true }
                    }
                } else if showAllFavorites && controller.favoritePages.count > sidebarStore.favoritesPreviewLimit {
                    SidebarSubtleActionRow(title: "Show less", leadingInset: SidebarMetrics.nestedInset) {
                        withAnimation(Motion.fast) { showAllFavorites = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func customSection(_ section: SidebarSection, index: Int) -> some View {
        let pages = sidebarStore.pages(for: section, in: controller.library)
        let otherSections = sidebarStore.sections.filter { $0.id != section.id }

        if renamingSectionId == section.id {
            SectionTitleField(placeholder: "Section name", text: $renameDraft, isFocused: $renameSectionFocused) {
                sidebarStore.renameSection(section.id, to: renameDraft)
                renamingSectionId = nil
            } onCancel: {
                renamingSectionId = nil
            }
        } else {
            CollapsibleSectionHeader(
                title: section.title,
                count: pages.count,
                isCollapsed: section.isCollapsed,
                onToggle: {
                    withAnimation(Motion.fast) {
                        sidebarStore.toggleCollapsed(section.id)
                    }
                }
            ) {
                PagesIcon()
            }
            .contextMenu {
                Button("Rename Section") {
                    renameDraft = section.title
                    renamingSectionId = section.id
                }
                if index > 0 {
                    Button("Move Up") {
                        withAnimation(Motion.morph) { sidebarStore.moveSection(section.id, up: true) }
                    }
                }
                if index + 1 < sidebarStore.sections.count {
                    Button("Move Down") {
                        withAnimation(Motion.morph) { sidebarStore.moveSection(section.id, up: false) }
                    }
                }
                if !otherSections.isEmpty {
                    Menu("Merge into") {
                        ForEach(otherSections) { target in
                            Button(target.title) {
                                withAnimation(Motion.morph) {
                                    sidebarStore.mergeSection(section.id, into: target.id)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Delete Section", role: .destructive) {
                    withAnimation(Motion.fast) { sidebarStore.deleteSection(section.id) }
                }
            }
        }

        if !section.isCollapsed {
            if pages.isEmpty {
                Text("Right-click a page to add")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, SidebarMetrics.nestedInset)
                    .frame(height: 24)
            } else {
                pageList(pages, section: section)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        CollapsibleSectionHeader(
            title: "Recent",
            count: recentPages.count,
            isCollapsed: sidebarStore.recentCollapsed,
            onToggle: {
                withAnimation(Motion.fast) {
                    sidebarStore.recentCollapsed.toggle()
                }
            }
        ) {
            ClockIcon()
        }
        .contextMenu {
            Button("Hide Recent Section") {
                withAnimation(Motion.fast) { sidebarStore.showRecent = false }
            }
        }

        if !sidebarStore.recentCollapsed {
            pageList(recentPages, section: nil)
        }
    }

    private var newSectionEditor: some View {
        SectionTitleField(placeholder: "New section", text: $newSectionTitle, isFocused: $newSectionFocused) {
            commitNewSection()
        } onCancel: {
            cancelNewSection()
        }
        .transition(.opacity)
    }

    private func beginNewSection(initialPageId: String? = nil) {
        pendingPageForNewSection = initialPageId
        newSectionTitle = ""
        withAnimation(Motion.fast) {
            isCreatingSection = true
        }
    }

    private func commitNewSection() {
        let pageId = pendingPageForNewSection
        if sidebarStore.createSection(title: newSectionTitle, initialPageId: pageId) != nil {
            newSectionTitle = ""
            pendingPageForNewSection = nil
            isCreatingSection = false
        } else {
            cancelNewSection()
        }
    }

    private func cancelNewSection() {
        newSectionTitle = ""
        pendingPageForNewSection = nil
        isCreatingSection = false
    }

    private func pageList(_ pages: [FfiPage], section: SidebarSection?) -> some View {
        VStack(spacing: 1) {
            ForEach(pages, id: \.id) { page in
                pageItem(page, section: section)
            }
        }
    }

    private func pageItem(_ page: FfiPage, section: SidebarSection?) -> some View {
        SidebarPageItem(
            page: page,
            section: section,
            allSections: sidebarStore.sections,
            sidebarStore: sidebarStore,
            isSelected: destination == .page(page.id),
            selectionNamespace: selectionNamespace,
            onOpen: { controller.selectPage(page.id) },
            onToggleFavorite: { controller.toggleFavorite(page.id) },
            onNewSectionWithPage: {
                beginNewSection(initialPageId: page.id)
            },
            onDelete: page.journalDay == nil ? { controller.requestDelete(page.id) } : nil
        )
    }
}

enum SidebarMetrics {
    static let outerInset: CGFloat = 10
    static let rowInset: CGFloat = 10
    static let iconWidth: CGFloat = 15
    static let iconGap: CGFloat = 9
    static let textRail: CGFloat = rowInset + iconWidth + iconGap
    static let nestedInset: CGFloat = textRail
    static let rowHeight: CGFloat = 28
}

private struct SearchFieldButton: View {
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                SearchIcon(size: 13)
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: SidebarMetrics.iconWidth)
                Text("Search")
                    .font(Typography.ui(13))
                    .foregroundColor(Theme.textTertiary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Theme.hover : Theme.canvas)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle(scale: 0.98))
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help("Search or create page (⌘K)")
        .accessibilityLabel("Search")
    }
}

private struct NewSectionIconButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            PlusIcon()
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isHovered ? Theme.hover : Theme.canvas)
                )
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle(scale: 0.96))
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help("New section")
        .accessibilityLabel("New section")
    }
}

private struct SectionsDivider: View {
    let onNewSection: () -> Void
    @State private var isHovered = false
    @State private var isButtonHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
            Button(action: onNewSection) {
                PlusIcon()
                    .foregroundColor(isButtonHovered ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isButtonHovered ? Theme.hover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .opacity(isHovered ? 1 : 0)
            .onHover { isButtonHovered = $0 }
            .help("New section")
            .accessibilityLabel("New section")
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.hover, value: isButtonHovered)
        .onHover { isHovered = $0 }
    }
}

private struct SectionTitleField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Color.clear.frame(width: SidebarMetrics.iconWidth, height: 1)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.ui(TypeScale.label, .medium))
                .tracking(0.3)
                .foregroundColor(Theme.textPrimary)
                .focused(isFocused)
                .onAppear { isFocused.wrappedValue = true }
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                .onChange(of: isFocused.wrappedValue) { focused in
                    if !focused { onCommit() }
                }
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
        .padding(.top, 11)
    }
}

private struct CollapsibleSectionHeader<Icon: View>: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: SidebarMetrics.iconGap) {
                ZStack {
                    if isHovered || isCollapsed {
                        ChevronIcon(expanded: !isCollapsed)
                            .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                    } else {
                        icon()
                            .scaleEffect(0.86)
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .frame(width: SidebarMetrics.iconWidth)

                HStack(spacing: 5) {
                    Text(title)
                        .font(Typography.ui(TypeScale.label, .medium))
                        .tracking(0.3)
                        .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(1)
                    if count > 0 {
                        Text("\(count)")
                            .font(Typography.ui(TypeScale.label))
                            .foregroundColor(Theme.textTertiary.opacity(0.75))
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 16)
            .padding(.bottom, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarSubtleActionRow: View {
    let title: String
    var showPlus: Bool = false
    var leadingInset: CGFloat = SidebarMetrics.rowInset
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                if showPlus {
                    PlusIcon()
                        .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                        .frame(width: SidebarMetrics.iconWidth)
                }
                Text(title)
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, SidebarMetrics.rowInset)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarNavItem<Icon: View>: View {
    let title: String
    var shortcut: String? = nil
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                icon()
                    .foregroundColor(isSelected ? Theme.textStrong : Theme.textTertiary)
                    .frame(width: SidebarMetrics.iconWidth)
                Text(title)
                    .font(Typography.ui(13, .medium))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut, isHovered {
                    Text(shortcut)
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: SidebarMetrics.rowHeight)
            .background(RowBackground(isSelected: isSelected, isHovered: isHovered, namespace: selectionNamespace))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarPageItem: View {
    let page: FfiPage
    let section: SidebarSection?
    let allSections: [SidebarSection]
    let sidebarStore: SidebarStore
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onNewSectionWithPage: () -> Void
    let onDelete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                Text(page.title)
                    .font(Typography.ui(13, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, SidebarMetrics.nestedInset)
            .padding(.trailing, SidebarMetrics.rowInset)
            .frame(height: SidebarMetrics.rowHeight)
            .background(RowBackground(isSelected: isSelected, isHovered: isHovered, namespace: selectionNamespace))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            if let section {
                Button("Remove from “\(section.title)”") {
                    withAnimation(Motion.fast) {
                        sidebarStore.removePage(page.id, from: section.id)
                    }
                }
            }
            Menu("Add to Section") {
                ForEach(allSections) { target in
                    let alreadyIn = sidebarStore.sectionContains(target.id, pageId: page.id)
                    Button(alreadyIn ? "✓ \(target.title)" : target.title) {
                        if alreadyIn {
                            sidebarStore.removePage(page.id, from: target.id)
                        } else {
                            sidebarStore.addPage(page.id, to: target.id)
                        }
                    }
                }
                if !allSections.isEmpty {
                    Divider()
                }
                Button("New Section…", action: onNewSectionWithPage)
            }
            if let onDelete {
                Divider()
                Button("Delete Page", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct RowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let namespace: Namespace.ID

    var body: some View {
        ZStack {
            if isHovered && !isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.hover)
                    .transition(.opacity)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.selected)
                    .matchedGeometryEffect(id: "sidebarActive", in: namespace)
            }
        }
    }
}

struct SidebarToggleButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SidebarToggleIcon()
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Theme.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }
}

struct ThemeToggleButton: View {
    @Binding var mode: ThemeMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(Motion.morph) {
                mode = ThemeMode.toggled(currentlyDark: colorScheme == .dark)
            }
        } label: {
            ZStack {
                if colorScheme == .dark {
                    SunIcon()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    MoonIcon()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .rotationEffect(.degrees(colorScheme == .dark ? 0 : -20))
            .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.morph, value: colorScheme)
        .help(colorScheme == .dark ? "Switch to light (⇧⌘L)" : "Switch to dark (⇧⌘L)")
        .accessibilityLabel(colorScheme == .dark ? "Switch to light appearance" : "Switch to dark appearance")
        .onHover { isHovered = $0 }
    }
}
