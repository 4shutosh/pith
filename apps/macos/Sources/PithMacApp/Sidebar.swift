import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                SidebarNavItem(title: "Today", shortcut: "⌘J", isSelected: controller.isShowingToday) {
                    TodayIcon()
                } action: {
                    controller.openTodayJournal()
                }
                SidebarNavItem(title: "All pages", isSelected: controller.isShowingAllPages) {
                    PagesIcon()
                } action: {
                    controller.showAllPages()
                }
                SidebarNavItem(title: "Search", shortcut: "⌘K", isSelected: false) {
                    SearchIcon()
                } action: {
                    showSearch = true
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !controller.favoritePages.isEmpty {
                        SectionLabel(title: "Favorites")
                        VStack(spacing: 2) {
                            ForEach(controller.favoritePages, id: \.id) { page in
                                SidebarPageItem(
                                    title: page.title,
                                    isSelected: !controller.isShowingAllPages && controller.selectedPageId == page.id
                                ) {
                                    controller.selectPage(page.id)
                                }
                            }
                        }
                    }

                    if !controller.journals.isEmpty {
                        SectionLabel(title: "Journals")
                        VStack(spacing: 2) {
                            ForEach(controller.journals.prefix(7), id: \.id) { page in
                                SidebarPageItem(
                                    title: page.title,
                                    isSelected: !controller.isShowingAllPages && controller.selectedPageId == page.id
                                ) {
                                    controller.selectPage(page.id)
                                }
                            }
                        }
                    }

                    if !controller.recentPages.isEmpty {
                        SectionLabel(title: "Recent")
                        VStack(spacing: 2) {
                            ForEach(controller.recentPages, id: \.id) { page in
                                SidebarPageItem(
                                    title: page.title,
                                    isSelected: !controller.isShowingAllPages && controller.selectedPageId == page.id
                                ) {
                                    controller.selectPage(page.id)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.top, 44)
        .padding(.horizontal, 10)
        .padding(.bottom, 44)
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(11, .medium))
            .tracking(0.4)
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .padding(.bottom, 6)
    }
}

private struct SidebarNavItem<Icon: View>: View {
    let title: String
    var shortcut: String? = nil
    let isSelected: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon()
                    .foregroundColor(isSelected ? Theme.accent : (isHovered ? Theme.textSecondary : Theme.textTertiary))
                    .frame(width: 15)
                Text(title)
                    .font(Typography.ui(13, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? Theme.textStrong : (isHovered ? Theme.textPrimary : Theme.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
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

private struct SidebarPageItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(Typography.ui(13, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? Theme.textStrong : (isHovered ? Theme.textPrimary : Theme.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
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
        .buttonStyle(.plain)
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
            mode = ThemeMode.toggled(currentlyDark: colorScheme == .dark)
        } label: {
            Group {
                if colorScheme == .dark {
                    SunIcon()
                } else {
                    MoonIcon()
                }
            }
            .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(colorScheme == .dark ? "Switch to light (⇧⌘L)" : "Switch to dark (⇧⌘L)")
        .accessibilityLabel(colorScheme == .dark ? "Switch to light appearance" : "Switch to dark appearance")
        .onHover { isHovered = $0 }
    }
}
