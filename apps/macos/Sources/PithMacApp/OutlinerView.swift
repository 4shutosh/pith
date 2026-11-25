import PithCore
import PithMacCore
import SwiftUI

struct PanelHeader: View {
    let crumbs: [String]
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("/").foregroundColor(Theme.bullet)
                }
                Text(crumb)
                    .foregroundColor(index == crumbs.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                    .fontWeight(index == crumbs.count - 1 ? .medium : .regular)
                    .lineLimit(1)
            }
            Spacer()
            if let trailing {
                Text(trailing).foregroundColor(Theme.textTertiary)
            }
        }
        .font(Typography.ui(13))
        .padding(.horizontal, 20)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

struct OutlinerView: View {
    @ObservedObject var controller: OutlinerController

    private var section: String {
        let isJournal = controller.selectedPageId == nil
            || controller.pages.first(where: { $0.id == controller.selectedPageId })?.journalDay != nil
        return isJournal ? "Journals" : "Pages"
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                crumbs: [section, controller.pageTitle ?? ""],
                trailing: controller.backlinks.isEmpty ? nil : "\(controller.backlinks.count) linked"
            )
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        content
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.top, 44)
                            .padding(.bottom, 120)
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
            Text(controller.pageTitle ?? "")
                .font(Typography.ui(28, .semibold))
                .tracking(-0.3)
                .foregroundColor(Theme.textStrong)
            Text(subtitle)
                .font(Typography.ui(13))
                .foregroundColor(Theme.textTertiary)
                .padding(.top, 6)
                .padding(.bottom, 26)

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
                            controller: controller
                        )
                        .id(row.id)
                    }
                }
            }

            if !controller.backlinks.isEmpty {
                LinkedReferences(controller: controller)
                    .padding(.top, 44)
            }
        }
    }

    private var subtitle: String {
        let count = controller.totalVisible
        let blocks = count == 1 ? "1 block" : "\(count) blocks"
        if controller.isShowingToday {
            return "Today · \(blocks)"
        }
        return blocks
    }
}

private struct OutlineRow: View {
    let row: FfiFlatBlockRow
    let isFocused: Bool
    let cursorOffset: Int?
    let cursorSeq: UInt64
    let controller: OutlinerController
    @State private var isHovered = false

    private static let indent: CGFloat = 24
    private static let guideX: CGFloat = 22.5
    private static let rowPadding: CGFloat = 3

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
                onTextChange: { text, composing in
                    controller.updateDraft(blockId: row.id, text: text, isComposing: composing)
                },
                onReturn: { controller.handleReturn(at: $0) },
                onCycleTask: { controller.cycleTask(caret: $0) },
                onBackspaceAtStart: { controller.handleBackspaceAtStart() },
                onTab: { controller.indentFocusedBlock() },
                onShiftTab: { controller.outdentFocusedBlock() },
                onMoveUp: { controller.moveFocusUp(column: $0) },
                onMoveDown: { controller.moveFocusDown(column: $0) },
                onEscape: { controller.blurFocus() }
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
                Image(systemName: row.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
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
            ZStack {
                if row.hasChildren && row.collapsed {
                    Circle()
                        .fill(Theme.bullet.opacity(0.35))
                        .frame(width: 14, height: 14)
                }
                Circle()
                    .fill(Theme.bullet)
                    .frame(width: 5, height: 5)
            }
            .accessibilityLabel(row.hasChildren && row.collapsed ? "Collapsed block" : "Block")
        }
    }
}

struct StatusIcon: View {
    let status: TaskStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(color)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .todo: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .later: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .todo, .later, .canceled: return Theme.textTertiary
        case .doing: return Theme.inProgress
        case .done: return Theme.accent
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
            Rectangle().fill(Theme.panelBorder).frame(height: 1)
            Text("Linked references · \(controller.backlinks.count)")
                .font(Typography.ui(12, .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 8)
            ForEach(controller.backlinks, id: \.blockId) { backlink in
                Button {
                    controller.selectPage(backlink.pageId)
                    controller.focusBlock(backlink.blockId)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backlink.pageTitle)
                            .font(Typography.ui(12))
                            .foregroundColor(Theme.textTertiary)
                        Text(InlineFormatter.format(backlink.spans))
                            .font(Typography.ui(14))
                            .foregroundColor(Theme.textBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hover))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.panelBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
