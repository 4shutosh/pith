import PithCore
import PithMacCore
import SwiftUI

struct LinkedReferences: View {
    @ObservedObject var controller: OutlinerController
    @AppStorage("pith.linkedReferencesCollapsed") private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            SectionToggle(count: controller.backlinks.count, isCollapsed: $isCollapsed)
                .padding(.top, 16)
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(BacklinkGroups.group(controller.backlinks), id: \.pageId) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            SourcePageLabel(title: group.pageTitle) {
                                controller.selectPage(group.pageId)
                            }
                            ForEach(group.backlinks, id: \.blockId) { backlink in
                                ReferenceRow(backlink: backlink) {
                                    controller.selectPage(backlink.pageId)
                                    controller.focusBlock(backlink.blockId)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}

private struct SectionToggle: View {
    let count: Int
    @Binding var isCollapsed: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("Linked references")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                Text("\(count)")
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(Theme.textTertiary)
                ChevronIcon(expanded: !isCollapsed)
                    .foregroundColor(Theme.textTertiary)
                    .opacity(isHovered || isCollapsed ? 1 : 0)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .help(isCollapsed ? "Show linked references" : "Hide linked references")
    }
}

private struct SourcePageLabel: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(TypeScale.ui, .medium))
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textSecondary)
                .underline(isHovered, color: Theme.textTertiary)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .help("Open \(title)")
    }
}

private struct ReferenceRow: View {
    let backlink: FfiBacklink
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Theme.bullet)
                    .frame(width: 4, height: 4)
                    .frame(width: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(InlineFormatter.format(backlink.spans))
                    .font(Typography.ui(TypeScale.listRow))
                    .foregroundColor(Theme.textBody)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Theme.hover : Color.clear)
                    .padding(.horizontal, -8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}
