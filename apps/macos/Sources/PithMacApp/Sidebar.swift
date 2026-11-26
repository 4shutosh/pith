import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool
    @State private var pendingDelete: FfiPage?

    private var destination: SidebarDestination? {
        controller.sidebarDestination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchFieldButton { showSearch = true }
                .padding(.bottom, 12)

            VStack(spacing: 1) {
                SidebarNavItem(title: "Journals", shortcut: "⌘J", isSelected: destination == .journals) {
                    TodayIcon()
                } action: {
                    controller.openTodayJournal()
                }
                SidebarNavItem(title: "All pages", shortcut: "⇧⌘P", isSelected: destination == .allPages) {
                    PagesIcon()
                } action: {
                    controller.showAllPages()
                }
            }

            SectionLabel(title: "Favorites")
            if controller.favoritePages.isEmpty {
                Text("Star a page to pin it here")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, SidebarMetrics.labelInset)
                    .frame(height: 24)
            } else {
                ViewThatFits(in: .vertical) {
                    pageList(controller.favoritePages)
                    ScrollView(showsIndicators: false) { pageList(controller.favoritePages) }
                }
                .layoutPriority(1)
            }

            if !controller.recentPages.isEmpty {
                SectionLabel(title: "Recent")
                ScrollView(showsIndicators: false) {
                    pageList(controller.recentPages)
                        .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 44)
        .padding(.horizontal, SidebarMetrics.outerInset)
        .confirmationDialog(
            "Delete page “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Page", role: .destructive) {
                if let page = pendingDelete {
                    controller.deletePage(page.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You can undo this with ⌘Z.")
        }
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
            onOpen: { controller.selectPage(page.id) },
            onToggleFavorite: { controller.toggleFavorite(page.id) },
            onDelete: page.journalDay == nil ? { pendingDelete = page } : nil
        )
    }
}

enum SidebarMetrics {
    static let outerInset: CGFloat = 10
    static let rowInset: CGFloat = 10
    static let iconWidth: CGFloat = 15
    static let iconGap: CGFloat = 9
    static let rowHeight: CGFloat = 28
    static let labelInset: CGFloat = rowInset + iconWidth + iconGap
}

private struct SearchFieldButton: View {
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
                Text("⌘K")
                    .font(Typography.ui(11))
                    .foregroundColor(Theme.textTertiary)
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
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Search or create page (⌘K)")
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
            .padding(.horizontal, SidebarMetrics.rowInset)
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
                }
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: SidebarMetrics.rowHeight)
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
    let onDelete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Group {
                    if page.journalDay != nil {
                        TodayIcon()
                    } else {
                        DocIcon()
                    }
                }
                .foregroundColor(isSelected ? Theme.textSecondary : Theme.bullet)
                .frame(width: SidebarMetrics.iconWidth)
                Text(page.title)
                    .font(Typography.ui(13, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: SidebarMetrics.rowHeight)
            .background(RowBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Theme.selected : (isHovered ? Theme.hover : Color.clear))
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
