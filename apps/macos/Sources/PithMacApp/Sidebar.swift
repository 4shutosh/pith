import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool

    private var destination: SidebarDestination? {
        controller.sidebarDestination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchFieldButton { showSearch = true }
                .padding(.bottom, 14)

            VStack(spacing: 1) {
                SidebarNavItem(title: "Journals", shortcut: "⌘J", isSelected: destination == .journals) {
                    TodayIcon()
                } action: {
                    controller.openTodayJournal()
                }
                SidebarNavItem(title: "Favorites", shortcut: "⇧⌘F", isSelected: destination == .favorites) {
                    StarIcon(filled: false)
                } action: {
                    controller.showFavorites()
                }
                SidebarNavItem(title: "All pages", shortcut: "⇧⌘P", isSelected: destination == .allPages) {
                    PagesIcon()
                } action: {
                    controller.showAllPages()
                }
            }

            if !controller.sidebarFavorites.isEmpty {
                SectionLabel(title: "Favorites")
                VStack(spacing: 1) {
                    ForEach(controller.sidebarFavorites, id: \.id) { page in
                        pageItem(page)
                    }
                    let hidden = controller.favoritePages.count - controller.sidebarFavorites.count
                    if hidden > 0 {
                        MoreLink(label: "View all \(controller.favoritePages.count)") {
                            controller.showFavorites()
                        }
                    }
                }
            }

            if !controller.recentPages.isEmpty {
                SectionLabel(title: "Recent")
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(controller.recentPages, id: \.id) { page in
                            pageItem(page)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 44)
        .padding(.horizontal, 10)
        .padding(.bottom, 48)
    }

    private func pageItem(_ page: FfiPage) -> some View {
        SidebarPageItem(
            page: page,
            isSelected: destination == .page(page.id),
            onOpen: { controller.selectPage(page.id) },
            onToggleFavorite: { controller.toggleFavorite(page.id) }
        )
    }
}

private struct SearchFieldButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SearchIcon(size: 13)
                    .foregroundColor(Theme.textTertiary)
                Text("Search")
                    .font(Typography.ui(13))
                    .foregroundColor(Theme.textTertiary)
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(Typography.ui(11))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Theme.hover : Theme.canvas)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Search")
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(11, .medium))
            .tracking(0.3)
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 5)
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
                    .foregroundColor(isSelected ? Theme.textStrong : Theme.textTertiary)
                    .frame(width: 15)
                Text(title)
                    .font(Typography.ui(13, .medium))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut, isHovered {
                    Text(shortcut)
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RowBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarPageItem: View {
    let page: FfiPage
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Group {
                    if page.journalDay != nil {
                        TodayIcon()
                    } else {
                        DocIcon()
                    }
                }
                .foregroundColor(isSelected ? Theme.textSecondary : Theme.bullet)
                .frame(width: 15)
                Text(page.title)
                    .font(Typography.ui(13))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RowBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
        }
    }
}

private struct RowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Theme.selected : (isHovered ? Theme.hover : Color.clear))
    }
}

private struct MoreLink: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typography.ui(12))
                .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                .padding(.leading, 34)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
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
