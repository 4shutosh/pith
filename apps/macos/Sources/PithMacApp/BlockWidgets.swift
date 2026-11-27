import AppKit
import PithCore
import PithMacCore
import SwiftUI

struct DividerBlockView: View {
    let onEdit: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onEdit) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(isHovered ? Theme.textTertiary : Theme.divider)
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
            .frame(height: BlockStyle.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

struct CodeBlockCard: View {
    let language: String?
    let code: String
    let onEdit: () -> Void
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? (language ?? "code") : "code")
                    .font(Typography.ui(TypeScale.label, .medium))
                    .foregroundColor(Theme.textTertiary)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(Typography.ui(TypeScale.label, .medium))
                        .foregroundColor(copied ? Theme.done : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                }
                .buttonStyle(PressButtonStyle(scale: 0.95))
                .cursor(.pointingHand)
                .opacity(isHovered || copied ? 1 : 0)
                .animation(Motion.fast, value: isHovered)
                .animation(Motion.fast, value: copied)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Button(action: onEdit) {
                Text(code.isEmpty ? " " : code)
                    .font(Typography.mono(TypeScale.code))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.iBeam)
        }
        .background(Theme.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }
}

struct PropertyChipsRow: View {
    let props: [FfiBlockProp]
    let onEdit: () -> Void

    var body: some View {
        ChipFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(props.enumerated()), id: \.offset) { _, prop in
                PropertyChip(prop: prop, onEdit: onEdit)
            }
        }
    }
}

private struct PropertyChip: View {
    let prop: FfiBlockProp
    let onEdit: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(prop.key)
                .font(Typography.ui(TypeScale.meta, .medium))
                .foregroundColor(Theme.textTertiary)
            Text(InlineFormatter.format(prop.valueSpans))
                .font(Typography.ui(TypeScale.meta))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Theme.selected : Theme.hover)
        )
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

private struct ChipFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
