import PithCore
import PithMacCore
import SwiftUI

struct PageListView: View {
    @ObservedObject var controller: OutlinerController
    let contentLeading: CGFloat
    let contentWidth: CGFloat
    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var pages: [FfiPage] {
        OutlinerController.recent(controller.pages, limit: controller.pages.count)
    }

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("All pages")
                        .font(Typography.ui(28, .semibold))
                        .tracking(-0.4)
                        .foregroundColor(Theme.textStrong)
                    Text(pages.count == 1 ? "1 page" : "\(pages.count) pages")
                        .font(Typography.ui(13))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 6)
                        .padding(.bottom, 24)

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
        .onHover { isHovered = $0 }
    }
}
