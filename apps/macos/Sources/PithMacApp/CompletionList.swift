import PithMacCore
import SwiftUI

struct CompletionList: View {
    let state: CompletionState
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                Button {
                    onPick(index)
                } label: {
                    HStack(spacing: 8) {
                        marker(for: item, selected: index == state.selected)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                                .font(Typography.ui(13, item.isNew ? .regular : .medium))
                                .foregroundColor(index == state.selected ? Theme.textStrong : Theme.textPrimary)
                                .lineLimit(1)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(Typography.ui(11))
                                    .foregroundColor(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == state.selected ? Theme.selected : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(5)
        .frame(width: 300)
        .background(Theme.elevated)
    }

    @ViewBuilder
    private func marker(for item: CompletionItem, selected: Bool) -> some View {
        let color = selected ? Theme.accent : Theme.textTertiary
        if item.isNew {
            PlusIcon().foregroundColor(color)
        } else {
            switch state.context.kind {
            case .page:
                Circle().fill(color).frame(width: 4.5, height: 4.5)
            case .tag:
                Text("#")
                    .font(Typography.ui(12, .medium))
                    .foregroundColor(selected ? Theme.tag : Theme.textTertiary)
            case .block:
                Circle().stroke(color, lineWidth: 1.2).frame(width: 5.5, height: 5.5)
            case .slash:
                Text("/")
                    .font(Typography.ui(12, .medium))
                    .foregroundColor(color)
            }
        }
    }
}
