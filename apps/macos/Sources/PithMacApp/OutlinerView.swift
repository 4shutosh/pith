import PithCore
import PithMacCore
import SwiftUI

struct OutlinerView: View {
    @ObservedObject var controller: OutlinerController
    @State private var showBacklinks: Bool = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let title = controller.pageTitle {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title)
                                .font(.system(size: 26, weight: .bold))
                            Spacer()
                            Text("\(controller.totalVisible) blocks")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 16)
                    }

                    if let conflict = controller.conflict {
                        ConflictBanner(conflict: conflict, controller: controller)
                            .padding(.bottom, 8)
                    }

                    if let err = controller.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.bottom, 8)
                    }

                    if controller.rows.isEmpty {
                        Button {
                            controller.ensureFirstBlockAndFocus()
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text("Click to start writing...")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(controller.rows, id: \.id) { row in
                                OutlinerRowView(
                                    row: row,
                                    isFocused: controller.focusedBlockId == row.id,
                                    controller: controller
                                )
                                .id(row.id)
                            }
                        }
                    }

                    if !controller.backlinks.isEmpty {
                        Divider()
                            .padding(.vertical, 20)

                        DisclosureGroup(
                            "Linked References (\(controller.backlinks.count))",
                            isExpanded: $showBacklinks
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(controller.backlinks, id: \.blockId) { bl in
                                    Button {
                                        controller.selectPage(bl.pageId)
                                        controller.focusBlock(bl.blockId)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bl.pageTitle)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(InlineFormatter.format(bl.spans))
                                                .font(.body)
                                                .foregroundColor(.primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(8)
                                        .background(Color.secondary.opacity(0.08))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: controller.focusedBlockId) { newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct OutlinerRowView: View {
    let row: FfiFlatBlockRow
    let isFocused: Bool
    @ObservedObject var controller: OutlinerController

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            bulletControl
                .frame(width: 18, height: 22)

            if isFocused {
                BlockTextEditor(
                    blockId: row.id,
                    text: $controller.draftText,
                    requestedCursorOffset: controller.requestedCursorOffset,
                    cursorRequestSeq: controller.cursorRequestSeq,
                    onTextChange: { text, composing in
                        controller.updateDraft(blockId: row.id, text: text, isComposing: composing)
                    },
                    onReturn: { offset in
                        controller.handleReturn(at: offset)
                    },
                    onBackspaceAtStart: {
                        controller.handleBackspaceAtStart()
                    },
                    onTab: {
                        controller.indentFocusedBlock()
                    },
                    onShiftTab: {
                        controller.outdentFocusedBlock()
                    },
                    onMoveUp: {
                        controller.moveFocusUp()
                    },
                    onMoveDown: {
                        controller.moveFocusDown()
                    },
                    onEscape: {
                        controller.blurFocus()
                    }
                )
            } else {
                inactiveText
            }
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bulletControl: some View {
        if row.hasChildren {
            Button {
                controller.toggleCollapse(row.id)
            } label: {
                Image(systemName: row.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
                .frame(width: 18, height: 22)
        }
    }

    private var inactiveText: some View {
        let display = row.spans.isEmpty
            ? AttributedString(" ")
            : InlineFormatter.format(row.spans)
        return Text(display)
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .environment(\.openURL, OpenURLAction { url in
                if let pageId = InlineFormatter.pageId(from: url) {
                    controller.openPage(id: pageId)
                    return .handled
                }
                return .systemAction
            })
            .onTapGesture {
                controller.focusBlock(row.id, cursorOffset: TextOffsets.length(row.renderedContent))
            }
    }
}

private struct ConflictBanner: View {
    let conflict: EditConflict
    @ObservedObject var controller: OutlinerController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This block was changed elsewhere while you were editing.")
                .font(.callout.weight(.semibold))
            Text("Theirs: \(conflict.theirs)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
            HStack {
                Button("Keep mine") { controller.keepMine() }
                Button("Use theirs") { controller.keepTheirs() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }
}
