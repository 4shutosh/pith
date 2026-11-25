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
                        Image(systemName: item.isNew ? "plus" : symbol)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                                .font(Typography.ui(13, item.isNew ? .regular : .medium))
                                .foregroundColor(Theme.textStrong)
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
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == state.selected ? Theme.accent.opacity(0.35) : Color.clear)
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

    private var symbol: String {
        switch state.context.kind {
        case .page: return "doc.text"
        case .tag: return "number"
        case .block: return "text.alignleft"
        }
    }
}
