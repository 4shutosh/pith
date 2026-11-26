import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct OutlinerView: View {
    @ObservedObject var controller: OutlinerController
    let contentLeading: CGFloat
    let contentWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(spacing: 0) {
                        content
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(.leading, contentLeading)
                            .padding(.top, 58)
                            .padding(.bottom, 140)
                        Spacer(minLength: 0)
                    }
                }
                .onChange(of: controller.focusedBlockId) { newId in
                    if let id = newId {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let pageId = InlineFormatter.pageId(from: url) {
                controller.openPage(id: pageId)
                return .handled
            }
            return .systemAction
        })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.zoomedBlockId != nil {
                ZoomTrailView(controller: controller)
                    .padding(.bottom, 18)
            } else {
                Text(controller.pageTitle ?? "")
                    .font(Typography.ui(28, .semibold))
                    .tracking(-0.4)
                    .foregroundColor(Theme.textStrong)
            }

            if controller.zoomedBlockId != nil {
                EmptyView()
            } else if let subtitle {
                Text(subtitle)
                    .font(Typography.ui(13))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
            } else {
                Spacer().frame(height: 26)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(Typography.ui(12))
                    .foregroundColor(Theme.danger)
                    .padding(.bottom, 10)
            }

            if controller.rows.isEmpty {
                Button {
                    controller.ensureFirstBlockAndFocus()
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.bullet).frame(width: 5, height: 5).frame(width: 18)
                        Text("Start writing…")
                            .font(Typography.ui(15))
                            .foregroundColor(Theme.textTertiary)
                        Spacer()
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rows, id: \.id) { row in
                        let isFocused = controller.focusedBlockId == row.id
                        OutlineRow(
                            row: row,
                            isFocused: isFocused,
                            cursorOffset: isFocused ? controller.requestedCursorOffset : nil,
                            cursorSeq: isFocused ? controller.cursorRequestSeq : 0,
                            completion: isFocused ? controller.completion : nil,
                            controller: controller
                        )
                        .id(row.id)
                    }
                }
            }

            if !controller.backlinks.isEmpty {
                LinkedReferences(controller: controller)
                    .padding(.top, 52)
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if controller.isShowingToday {
            parts.append("Today")
        }
        if !controller.backlinks.isEmpty {
            let count = controller.backlinks.count
            parts.append(count == 1 ? "1 linked reference" : "\(count) linked references")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct OutlineRow: View {
    let row: FfiFlatBlockRow
    let isFocused: Bool
    let cursorOffset: Int?
    let cursorSeq: UInt64
    let completion: CompletionState?
    let controller: OutlinerController
    @State private var isHovered = false

    private static let indent: CGFloat = 24
    private static let guideX: CGFloat = 22.5
    private static let rowPadding: CGFloat = 4

    var body: some View {
        let presentation = BlockPresentation.runs(row.spans)
        HStack(alignment: .top, spacing: 0) {
            disclosure
                .frame(width: 14, height: BlockStyle.lineHeight)
            marker(presentation.status)
                .frame(width: 18, height: BlockStyle.lineHeight)
            BlockTextView(
                blockId: row.id,
                isEditing: isFocused,
                display: BlockStyle.display(presentation.runs, closed: presentation.status?.isClosed ?? false),
                runs: presentation.runs,
                text: Binding(get: { controller.draftText }, set: { controller.draftText = $0 }),
                requestedCursorOffset: cursorOffset,
                cursorRequestSeq: cursorSeq,
                onActivate: { controller.focusBlock(row.id, cursorOffset: $0) },
                onOpenPage: { controller.openPage(id: $0) },
                onTextChange: { text, composing, caret in
                    controller.updateDraft(blockId: row.id, text: text, isComposing: composing, caret: caret)
                },
                onReturn: { controller.handleReturn(at: $0) },
                onCycleTask: { controller.cycleTask(caret: $0) },
                onBackspaceAtStart: { controller.handleBackspaceAtStart() },
                onTab: { controller.indentFocusedBlock() },
                onShiftTab: { controller.outdentFocusedBlock() },
                onMoveUp: { controller.moveFocusUp(column: $0) },
                onMoveDown: { controller.moveFocusDown(column: $0) },
                onEscape: { controller.blurFocus() },
                completion: completion,
                onCompletionMove: { controller.moveCompletion($0) },
                onCompletionAccept: { controller.acceptCompletion(at: $0) },
                onCompletionDismiss: { controller.dismissCompletion() },
                onMoveBlock: { controller.moveFocusedBlock(up: $0, caret: $1) },
                onToggleCollapse: { controller.toggleFocusedCollapse(caret: $0) },
                onCopyMarkdown: {
                    guard let markdown = controller.focusedBlockMarkdown() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                },
                onPaste: { controller.paste($0, selectionStart: $1, selectionEnd: $2) }
            )
            .padding(.leading, 8)
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.vertical, Self.rowPadding)
        .background(alignment: .topLeading) { guides }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var guides: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Int(row.depth), id: \.self) { level in
                Rectangle()
                    .fill(Theme.guide)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: CGFloat(level) * Self.indent + Self.guideX)
            }
            if row.hasChildren && !row.collapsed {
                Rectangle()
                    .fill(Theme.guide)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, Self.rowPadding + BlockStyle.lineHeight / 2 + 7)
                    .offset(x: CGFloat(row.depth) * Self.indent + Self.guideX)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button {
                controller.toggleCollapse(row.id)
            } label: {
                ChevronIcon(expanded: !row.collapsed)
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 14, height: BlockStyle.lineHeight)
                    .contentShape(Rectangle())
                    .opacity(isHovered ? 1 : 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.collapsed ? "Expand" : "Collapse")
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func marker(_ status: TaskStatus?) -> some View {
        if let status {
            Button {
                controller.toggleTaskDone(row.id)
            } label: {
                StatusIcon(status: status)
                    .frame(width: 18, height: BlockStyle.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                controller.zoom(into: row.id)
            } label: {
                ZStack {
                    if row.hasChildren && row.collapsed {
                        Circle()
                            .fill(Theme.bullet.opacity(0.35))
                            .frame(width: 14, height: 14)
                    }
                    Circle()
                        .fill(isHovered ? Theme.textSecondary : Theme.bullet)
                        .frame(width: 5, height: 5)
                }
                .frame(width: 18, height: BlockStyle.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.hasChildren && row.collapsed ? "Zoom into collapsed block" : "Zoom into block")
        }
    }
}

struct StatusIcon: View {
    let status: TaskStatus

    var body: some View {
        TaskMark(status: status)
            .foregroundColor(color)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .todo, .later, .canceled: return Theme.textTertiary
        case .doing: return Theme.inProgress
        case .done: return Theme.done
        }
    }

    private var label: String {
        switch status {
        case .todo: return "To do"
        case .doing: return "In progress"
        case .later: return "Later"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }
}

private struct LinkedReferences: View {
    @ObservedObject var controller: OutlinerController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text("Linked references · \(controller.backlinks.count)")
                .font(Typography.ui(12, .medium))
                .foregroundColor(Theme.textTertiary)
                .padding(.top, 10)
            ForEach(controller.backlinks, id: \.blockId) { backlink in
                BacklinkCard(backlink: backlink) {
                    controller.selectPage(backlink.pageId)
                    controller.focusBlock(backlink.blockId)
                }
            }
        }
    }
}

private struct BacklinkCard: View {
    let backlink: FfiBacklink
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(backlink.pageTitle)
                    .font(Typography.ui(12, .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(InlineFormatter.format(backlink.spans))
                    .font(Typography.ui(14))
                    .foregroundColor(Theme.textBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.hover : Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct ZoomTrailView: View {
    @ObservedObject var controller: OutlinerController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(ZoomTrail.items(controller.breadcrumb, maxVisible: 4).enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    ChevronIcon(expanded: false)
                        .foregroundColor(Theme.bullet)
                        .frame(width: 14)
                }
                switch item {
                case let .crumb(crumb):
                    TrailButton(label: crumb.label) { controller.zoomOut(to: crumb) }
                case let .hidden(crumbs):
                    Menu {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                            Button(crumb.label) { controller.zoomOut(to: crumb) }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .font(Typography.ui(13))
        .padding(.leading, -6)
    }
}

private struct TrailButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
