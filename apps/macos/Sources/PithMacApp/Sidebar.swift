import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @Binding var showSearch: Bool
    @Namespace private var selectionNamespace

    private var destination: SidebarDestination? {
        controller.sidebarDestination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchFieldButton(shortcut: shortcuts.displayString(for: .openPalette)) {
                withAnimation(Motion.pop) { showSearch = true }
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

            SectionLabel(title: "Favorites") { StarIcon(filled: false) }
            if controller.favoritePages.isEmpty {
                Text("Star a page to pin it here")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, SidebarMetrics.rowInset)
                    .frame(height: 24)
            } else {
                ViewThatFits(in: .vertical) {
                    pageList(controller.favoritePages)
                    ScrollView(showsIndicators: false) { pageList(controller.favoritePages) }
                }
                .layoutPriority(1)
                .animation(Motion.morph, value: controller.favoritePages.map(\.id))
            }

            if !controller.recentPages.isEmpty {
                SectionLabel(title: "Recent") { ClockIcon() }
                ScrollView(showsIndicators: false) {
                    pageList(controller.recentPages)
                        .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
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
        .padding(.top, 44)
        .padding(.horizontal, SidebarMetrics.outerInset)
        .animation(Motion.morph, value: destination)
    }

    private func pageList(_ pages: [FfiPage]) -> some View {
        VStack(spacing: 1) {
            ForEach(pages, id: \.id) { page in
                pageItem(page)
            }
        }
    }

    private func pageItem(_ page: FfiPage) -> some View {
        SidebarPageItem(
            page: page,
            isSelected: destination == .page(page.id),
            selectionNamespace: selectionNamespace,
            onOpen: { controller.selectPage(page.id) },
            onToggleFavorite: { controller.toggleFavorite(page.id) },
            onDelete: page.journalDay == nil ? { controller.requestDelete(page.id) } : nil
        )
    }
}

enum SidebarMetrics {
    static let outerInset: CGFloat = 10
    static let rowInset: CGFloat = 10
    static let iconWidth: CGFloat = 15
    static let iconGap: CGFloat = 9
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

private struct SectionLabel<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Typography.ui(TypeScale.label, .medium))
                .tracking(0.3)
                .foregroundColor(Theme.textTertiary)
            Spacer(minLength: 0)
            icon()
                .scaleEffect(0.86)
                .foregroundColor(Theme.textTertiary)
                .frame(width: SidebarMetrics.iconWidth)
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .padding(.top, 24)
        .padding(.bottom, 6)
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
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
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
            .padding(.horizontal, SidebarMetrics.rowInset)
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
