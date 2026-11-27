import PithMacCore
import SwiftUI

struct FilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let namespace: Namespace.ID
    let selectionId: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Typography.ui(12, isSelected ? .medium : .regular))
                    .foregroundColor(isSelected || isHovered ? Theme.textStrong : Theme.textSecondary)
                if let count {
                    Text("\(count)")
                        .font(Typography.ui(11).monospacedDigit())
                        .foregroundColor(Theme.textTertiary)
                        .contentTransition(.numericText())
                }
            }
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background {
                ZStack {
                    if isHovered && !isSelected {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.hover)
                    }
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.selected)
                            .matchedGeometryEffect(id: selectionId, in: namespace)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                content()
            }
        }
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 24)
            }
        )
    }
}
