import PithMacCore
import SwiftUI

struct FindBar: View {
    let controller: OutlinerController
    @ObservedObject var find: FindState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SearchIcon(size: 13)
                .foregroundColor(Theme.textTertiary)

            TextField("Find in page…", text: Binding(
                get: { find.query },
                set: { controller.updateFindQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(Typography.ui(TypeScale.ui))
            .foregroundColor(Theme.textPrimary)
            .focused($isFieldFocused)
            .frame(width: 180)
            .onAppear { isFieldFocused = true }

            if !find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(matchLabel)
                    .font(Typography.ui(TypeScale.meta))
                    .foregroundColor(find.matches.isEmpty ? Theme.danger : Theme.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.fast, value: find.activeIndex)
            }

            HStack(spacing: 2) {
                FindNavButton(direction: .up, disabled: find.matches.isEmpty) {
                    controller.previousFindMatch()
                }
                FindNavButton(direction: .down, disabled: find.matches.isEmpty) {
                    controller.nextFindMatch()
                }
                FindCloseButton {
                    controller.closeFind()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.elevatedBorder, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 16, y: 6)
        .keyScope(.overlay, whileEditingText: true, isActive: find.isOpen) { stroke in
            switch (stroke.key, stroke.modifiers) {
            case (.escape, []):
                controller.closeFind()
                return true
            case (.returnKey, []):
                controller.nextFindMatch()
                return true
            case (.returnKey, .shift):
                controller.previousFindMatch()
                return true
            default:
                return false
            }
        }
    }

    private var matchLabel: String {
        if find.matches.isEmpty {
            return "0 / 0"
        }
        return "\(find.activeIndex + 1) / \(find.matches.count)"
    }
}

private enum FindDirection {
    case up
    case down
}

private struct FindNavButton: View {
    let direction: FindDirection
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ChevronIcon(expanded: false)
                .rotationEffect(.degrees(direction == .up ? -90 : 90))
                .foregroundColor(disabled ? Theme.textTertiary.opacity(0.4) : (isHovered ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered && !disabled ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help(direction == .up ? "Previous match (⇧↵)" : "Next match (↵)")
    }
}

private struct FindCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 3, y: 3))
                path.addLine(to: CGPoint(x: size.width - 3, y: size.height - 3))
                path.move(to: CGPoint(x: size.width - 3, y: 3))
                path.addLine(to: CGPoint(x: 3, y: size.height - 3))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
            }
            .frame(width: 12, height: 12)
            .foregroundColor(isHovered ? Theme.textPrimary : Theme.textTertiary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help("Close find (Esc)")
    }
}
