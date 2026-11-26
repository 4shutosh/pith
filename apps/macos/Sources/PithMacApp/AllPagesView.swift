import PithCore
import PithMacCore
import SwiftUI

struct AllPagesView: View {
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
                    Text(controller.pages.count == 1 ? "1 page" : "\(controller.pages.count) pages")
                        .font(Typography.ui(13))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 6)
                        .padding(.bottom, 24)

                    LazyVStack(spacing: 2) {
                        ForEach(pages, id: \.id) { page in
                            PageRow(page: page, updated: updatedLabel(page)) {
                                controller.selectPage(page.id)
                            }
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
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(page.title)
                    .font(Typography.ui(14))
                    .foregroundColor(isHovered ? Theme.textStrong : Theme.textPrimary)
                    .lineLimit(1)
                if page.journalDay != nil {
                    Text("Journal")
                        .font(Typography.ui(11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.elevated))
                }
                Spacer()
                Text(updated)
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
