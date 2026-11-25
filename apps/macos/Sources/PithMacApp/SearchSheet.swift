import PithCore
import PithMacCore
import SwiftUI

struct QuickSearchSheet: View {
    @ObservedObject var controller: OutlinerController
    @Binding var isPresented: Bool
    @State private var query: String = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pageHits: [FfiSearchHit] {
        controller.searchHits.filter { if case .page = $0 { return true } else { return false } }
    }

    private var blockHits: [FfiSearchHit] {
        controller.searchHits.filter { if case .block = $0 { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textTertiary)
                TextField("Search or create a page", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(17))
                    .foregroundColor(Theme.textStrong)
                    .onChange(of: query) { controller.runSearch($0) }
                    .onSubmit(openFirst)
                if !controller.searchHits.isEmpty {
                    Text("\(controller.searchHits.count) results")
                        .font(Typography.ui(12))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !pageHits.isEmpty {
                        GroupLabel(title: "Pages")
                        ForEach(Array(pageHits.enumerated()), id: \.offset) { index, hit in
                            HitRow(hit: hit, isFirst: index == 0) { open(hit) }
                        }
                    }
                    if !blockHits.isEmpty {
                        GroupLabel(title: "Blocks")
                        ForEach(Array(blockHits.enumerated()), id: \.offset) { index, hit in
                            HitRow(hit: hit, isFirst: pageHits.isEmpty && index == 0) { open(hit) }
                        }
                    }
                    if SearchPresentation.offersCreatePage(query: query, hits: controller.searchHits) {
                        CreatePageRow(title: trimmedQuery, action: createPage)
                    }
                }
                .padding(6)
            }

            HStack(spacing: 18) {
                KeyHint(keys: "↵", label: "Open")
                KeyHint(keys: "esc", label: "Close")
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
        .frame(width: 680, height: 500)
        .background(Theme.elevated)
        .preferredColorScheme(.dark)
    }

    private func open(_ hit: FfiSearchHit) {
        controller.openSearchHit(hit)
        isPresented = false
    }

    private func openFirst() {
        if let first = controller.searchHits.first {
            open(first)
        } else if !trimmedQuery.isEmpty {
            createPage()
        }
    }

    private func createPage() {
        controller.openPageByTitle(trimmedQuery)
        isPresented = false
    }
}

private struct GroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(12, .medium))
            .foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct HitRow: View {
    let hit: FfiSearchHit
    let isFirst: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                icon.frame(width: 16, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    switch hit {
                    case let .page(_, _, highlightedTitle):
                        Text(SearchPresentation.highlighted(highlightedTitle))
                            .font(Typography.ui(14, .medium))
                            .foregroundColor(Theme.textStrong)
                    case let .block(_, _, _, breadcrumb, snippet, _, _):
                        Text(SearchPresentation.breadcrumb(breadcrumb))
                            .font(Typography.ui(12))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                        Text(SearchPresentation.highlighted(snippet))
                            .font(Typography.ui(14))
                            .foregroundColor(Theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFirst || isHovered ? Theme.rowSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch hit {
        case .page:
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        case .block:
            Circle().fill(Theme.bullet).frame(width: 5, height: 5).padding(.top, 20)
        }
    }
}

private struct CreatePageRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 16)
                Text("Create page")
                    .font(Typography.ui(14, .medium))
                    .foregroundColor(Theme.textStrong)
                Text("“\(title)”")
                    .font(Typography.ui(14))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(Typography.ui(11))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 5)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.elevatedBorder, lineWidth: 1))
            Text(label)
                .font(Typography.ui(12))
                .foregroundColor(Theme.textTertiary)
        }
    }
}
