import PithCore
import PithMacCore
import SwiftUI

struct AllPagesView: View {
    @ObservedObject var controller: OutlinerController
    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var pages: [FfiPage] {
        OutlinerController.recent(controller.pages, limit: controller.pages.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(crumbs: ["All pages"], trailing: "\(controller.pages.count) pages")
            HStack {
                Text("Title")
                Spacer()
                Text("Updated").frame(width: 120, alignment: .leading)
            }
            .font(Typography.ui(12))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 24)
            .frame(height: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages, id: \.id) { page in
                        PageRow(page: page, updated: updatedLabel(page)) {
                            controller.selectPage(page.id)
                        }
                    }
                }
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
            HStack(spacing: 12) {
                Image(systemName: page.journalDay == nil ? "doc.text" : "calendar")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 16)
                Text(page.title)
                    .font(Typography.ui(14))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(updated)
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 120, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .frame(height: 40)
            .background(isHovered ? Theme.hover : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
