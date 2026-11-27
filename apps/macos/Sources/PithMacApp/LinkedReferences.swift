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
        .animation(Motion.hover, value: isHovered)
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
        .animation(Motion.hover, value: isHovered)
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
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct UnlinkedReferences: View {
    @ObservedObject var controller: OutlinerController
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            UnlinkedSectionToggle(
                count: controller.unlinkedRefsLoaded ? controller.unlinkedRefs.count : nil,
                isExpanded: $isExpanded
            ) {
                isExpanded.toggle()
                if isExpanded && !controller.unlinkedRefsLoaded {
                    controller.loadUnlinkedReferences()
                }
            }
            .padding(.top, 16)

            if isExpanded {
                if controller.unlinkedRefs.isEmpty {
                    Text("No unlinked mentions")
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 10)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(BacklinkGroups.groupUnlinked(controller.unlinkedRefs), id: \.pageId) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                SourcePageLabel(title: group.pageTitle) {
                                    controller.selectPage(group.pageId)
                                }
                                ForEach(group.refs, id: \.blockId) { ref in
                                    UnlinkedReferenceRow(
                                        ref: ref,
                                        onOpen: {
                                            controller.openBlock(id: ref.blockId)
                                        },
                                        onLink: {
                                            controller.linkUnlinkedReference(blockId: ref.blockId)
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
        .onChange(of: controller.selectedPageId) { _ in
            isExpanded = false
        }
    }
}

private struct UnlinkedSectionToggle: View {
    let count: Int?
    @Binding var isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Unlinked references")
                    .font(Typography.ui(TypeScale.meta, .medium))
                    .foregroundColor(isHovered ? Theme.textSecondary : Theme.textTertiary)
                if let count {
                    Text("\(count)")
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(Theme.textTertiary)
                        .contentTransition(.numericText())
                }
                ChevronIcon(expanded: isExpanded)
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "Hide unlinked references" : "Search for unlinked mentions")
    }
}

private struct UnlinkedReferenceRow: View {
    let ref: FfiUnlinkedRef
    let onOpen: () -> Void
    let onLink: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Theme.bullet)
                        .frame(width: 4, height: 4)
                        .frame(width: 10)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(InlineFormatter.format(ref.spans))
                        .font(Typography.ui(TypeScale.listRow))
                        .foregroundColor(Theme.textBody)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)

            Button(action: onLink) {
                Text("Link")
                    .font(Typography.ui(TypeScale.label, .medium))
                    .foregroundColor(Theme.link)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.elevatedBorder, lineWidth: 1))
            }
            .buttonStyle(PressButtonStyle(scale: 0.96))
            .cursor(.pointingHand)
            .opacity(isHovered ? 1 : 0)
            .animation(Motion.fast, value: isHovered)
            .help("Convert mention into a [[page link]]")
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Theme.hover : Color.clear)
                .padding(.horizontal, -8)
        )
        .onHover { isHovered = $0 }
    }
}
