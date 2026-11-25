import PithCore
import PithMacCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.accent)
                    .frame(width: 20, height: 20)
                    .overlay(Text("p").font(Typography.ui(12, .semibold)).foregroundColor(.white))
                Text("pith")
                    .font(Typography.ui(14, .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                IconButton(symbol: "magnifyingglass", label: "Search") { showSearch = true }
                IconButton(symbol: "square.and.pencil", label: "New page", filled: true) { showSearch = true }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)

            VStack(spacing: 1) {
                SidebarItem(symbol: "calendar", title: "Today", isSelected: controller.isShowingToday) {
                    controller.openTodayJournal()
                }
                SidebarItem(symbol: "doc.on.doc", title: "All pages", isSelected: controller.isShowingAllPages) {
                    controller.showAllPages()
                }
                SidebarItem(symbol: "magnifyingglass", title: "Search", shortcut: "⌘K", isSelected: false) {
                    showSearch = true
                }
            }

            if !controller.recentPages.isEmpty {
                SectionLabel(title: "Recent")
                VStack(spacing: 1) {
                    ForEach(controller.recentPages, id: \.id) { page in
                        SidebarItem(
                            symbol: page.journalDay == nil ? "doc.text" : "calendar",
                            title: page.title,
                            isSelected: !controller.isShowingAllPages && controller.selectedPageId == page.id
                        ) {
                            controller.selectPage(page.id)
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Circle().fill(Theme.healthy).frame(width: 7, height: 7)
                Text("Local graph · \(controller.pages.count) pages")
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(8)
        }
        .padding(.top, 40)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(12, .medium))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }
}

struct SidebarItem: View {
    let symbol: String
    let title: String
    var shortcut: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16)
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(title)
                    .font(Typography.ui(13, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? Theme.textStrong : Theme.textBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
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

struct IconButton: View {
    let symbol: String
    let label: String
    var filled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(filled || isHovered ? Theme.selected : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }
}
