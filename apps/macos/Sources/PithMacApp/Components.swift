import PithCore
import PithMacCore
import SwiftUI

struct ScreenHeader<Subtitle: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                trailing()
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                trailing()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScreenTitle(title: title)
            subtitle()
                .font(Typography.ui(TypeScale.ui))
                .foregroundColor(Theme.textTertiary)
        }
    }
}

struct ScreenTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(TypeScale.pageTitle, .semibold))
            .tracking(-0.4)
            .foregroundColor(Theme.textStrong)
            .lineLimit(1)
            .fixedSize()
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(TypeScale.meta, .medium))
                .foregroundColor(Theme.textSecondary)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(PressButtonStyle(scale: 0.97))
        .cursor(.pointingHand)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var shortcutHint: String? = nil
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            SearchIcon(size: 12)
                .foregroundColor(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.ui(TypeScale.ui))
                .foregroundColor(Theme.textStrong)
                .focused(isFocused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    ClearIcon()
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help("Clear (esc)")
            } else if let shortcutHint, !isFocused.wrappedValue {
                Keycap(shortcutHint, size: .small)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused.wrappedValue ? Theme.accent.opacity(0.6) : Theme.elevatedBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
        .cursor(.iBeam)
    }
}

struct Keycap: View {
    enum Size {
        case small
        case regular
    }

    let label: String
    var size: Size = .regular
    var tint: Color = Theme.textSecondary

    init(_ label: String, size: Size = .regular, tint: Color = Theme.textSecondary) {
        self.label = label
        self.size = size
        self.tint = tint
    }

    var body: some View {
        Text(label)
            .font(Typography.ui(size == .small ? TypeScale.label : TypeScale.meta, .medium))
            .foregroundColor(tint)
            .fixedSize()
            .padding(.horizontal, size == .small ? 4 : 5)
            .frame(minWidth: size == .small ? 16 : 22, minHeight: size == .small ? 16 : 22)
            .background(RoundedRectangle(cornerRadius: size == .small ? 4 : 6).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: size == .small ? 4 : 6).stroke(Theme.elevatedBorder, lineWidth: 1))
    }
}

struct KeycapRow: View {
    let caps: [String]
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Keycap(cap, tint: tint)
            }
        }
        .fixedSize()
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.ui(TypeScale.label, .medium))
            .tracking(0.3)
            .foregroundColor(Theme.textTertiary)
    }
}

struct Card<Content: View>: View {
    let title: String?
    var count: Int? = nil
    var contentPadding: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Typography.ui(TypeScale.ui, .semibold))
                        .foregroundColor(Theme.textStrong)
                        .lineLimit(1)
                    if let count {
                        Text("\(count)")
                            .font(Typography.ui(TypeScale.label, .medium))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            content()
                .padding(contentPadding)
        }
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }
}

struct AdaptiveGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let width: CGFloat
    let minimumColumnWidth: CGFloat
    var spacing: CGFloat = 12
    var maximumColumns: Int = 2
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        let count = AdaptiveColumns.count(
            width: width,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing,
            maximum: maximumColumns
        )
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count),
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(items) { item in
                cell(item)
            }
        }
    }
}

struct SettingRow<Label: View, Control: View>: View {
    let stacked: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let control: () -> Control

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                label()
                control()
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 16) {
                label()
                Spacer(minLength: 0)
                control()
                    .fixedSize()
            }
        }
    }
}

struct SegmentedGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Keycap(keys, size: .small)
            Text(label)
                .font(Typography.ui(12))
                .foregroundColor(Theme.textTertiary)
        }
    }
}

struct OutlineLine: View {
    let depth: UInt32
    let spans: [FfiSpan]
    let isTarget: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isTarget ? Theme.accent : Theme.bullet)
                .frame(width: 4.5, height: 4.5)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(InlineFormatter.format(spans))
                .font(Typography.ui(TypeScale.ui))
                .foregroundColor(isTarget ? Theme.textStrong : Theme.textBody)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(depth, 4)) * 16)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isTarget ? Theme.rowSelected : Color.clear))
    }
}

struct PreviewNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.ui(TypeScale.meta))
            .foregroundColor(Theme.textTertiary)
    }
}
