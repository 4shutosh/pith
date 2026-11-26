import PithCore
import PithMacCore
import SwiftUI

private enum PageFilter: String, CaseIterable {
    case all = "All"
    case pages = "Pages"
    case favorites = "Favorites"
}

struct PageListView: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool
    let contentLeading: CGFloat
    let contentWidth: CGFloat
    @State private var filter: PageFilter = .all
    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var pages: [FfiPage] {
        let source: [FfiPage]
        switch filter {
        case .all:
            source = controller.pages
        case .pages:
            source = controller.pages.filter { $0.journalDay == nil }
        case .favorites:
            source = controller.pages.filter(\.favorite)
        }
        return OutlinerController.recent(source, limit: source.count)
    }

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        Text("All pages")
                            .font(Typography.ui(28, .semibold))
                            .tracking(-0.4)
                            .foregroundColor(Theme.textStrong)
                        Spacer()
                        Button {
                            showSearch = true
                        } label: {
                            HStack(spacing: 5) {
                                PlusIcon()
                                Text("New")
                                    .font(Typography.ui(12, .medium))
                            }
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Create or open page (⌘K)")
                    }

                    HStack(spacing: 6) {
                        ForEach(PageFilter.allCases, id: \.self) { option in
                            FilterChip(title: option.rawValue, isSelected: filter == option) {
                                filter = option
                            }
                        }
                        Spacer()
                        Text(pages.count == 1 ? "1 page" : "\(pages.count) pages")
                            .font(Typography.ui(12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                    LazyVStack(spacing: 2) {
                        ForEach(pages, id: \.id) { page in
                            PageRow(
                                page: page,
                                updated: updatedLabel(page),
                                onOpen: { controller.selectPage(page.id) },
                                onToggleFavorite: { controller.toggleFavorite(page.id) }
                            )
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, contentLeading)
                .padding(.top, 58)
                .padding(.bottom, 100)
                Spacer(minLength: 0)
            }
        }
    }

    private func updatedLabel(_ page: FfiPage) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(page.updatedAt) / 1000)
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(12, isSelected ? .medium : .regular))
                .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textTertiary)
                .padding(.horizontal, 10)
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

private struct PageRow: View {
    let page: FfiPage
    let updated: String
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Group {
                        if page.journalDay != nil {
                            TodayIcon()
                        } else {
                            DocIcon()
                        }
                    }
                    .foregroundColor(Theme.textTertiary)
                    Text(page.title)
                        .font(Typography.ui(14))
                        .foregroundColor(isHovered ? Theme.textStrong : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(updated)
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleFavorite) {
                StarIcon(filled: page.favorite)
                    .foregroundColor(page.favorite ? Theme.accent : Theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(page.favorite || isHovered ? 1 : 0)
            .help(page.favorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Theme.hover : Color.clear)
        )
        .padding(.horizontal, -12)
        .onHover { isHovered = $0 }
    }
}
