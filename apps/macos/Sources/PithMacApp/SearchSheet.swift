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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search or create a page", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .padding(16)
                .onChange(of: query) { controller.runSearch($0) }
                .onSubmit(openFirst)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.searchHits.enumerated()), id: \.offset) { _, hit in
                        Button { open(hit) } label: { HitRow(hit: hit) }
                            .buttonStyle(.plain)
                    }
                    if SearchPresentation.offersCreatePage(query: query, hits: controller.searchHits) {
                        Button(action: createPage) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.badge.plus")
                                    .frame(width: 22)
                                Text("Create page").font(.body.weight(.semibold))
                                Text("— Create page called '\(trimmedQuery)'")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 640, height: 480)
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

private struct HitRow: View {
    let hit: FfiSearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                switch hit {
                case let .page(_, _, highlightedTitle):
                    Text(SearchPresentation.highlighted(highlightedTitle))
                        .font(.body.weight(.semibold))
                case let .block(_, _, _, breadcrumb, snippet, _, _):
                    Text(SearchPresentation.breadcrumb(breadcrumb))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(SearchPresentation.highlighted(snippet))
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch hit {
        case .page:
            Image(systemName: "doc.text").foregroundColor(.accentColor)
        case .block:
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 8)
        }
    }
}
