import PithCore
import PithMacCore
import SwiftUI

enum HoverPreviewTarget: Equatable {
    case page(String)
    case block(String)
}

struct HoverPreviewView: View {
    let preview: FfiLinkPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PreviewWording.title(preview))
                    .font(Typography.ui(TypeScale.ui, .semibold))
                    .foregroundColor(preview.deleted ? Theme.textTertiary : Theme.textStrong)
                    .strikethrough(preview.deleted, color: Theme.textTertiary)
                    .lineLimit(1)
                if let subtitle = PreviewWording.subtitle(preview) {
                    Text(subtitle)
                        .font(Typography.ui(TypeScale.label))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            if !preview.lines.isEmpty {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(Theme.bullet)
                                .frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                            Text(InlineFormatter.format(line.spans))
                                .font(Typography.ui(TypeScale.meta))
                                .foregroundColor(Theme.textBody)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, CGFloat(min(line.depth, 3)) * 12)
                    }
                }
            }

            if preview.totalBlocks > UInt64(preview.lines.count) {
                let remaining = preview.totalBlocks - UInt64(preview.lines.count)
                Text("+\(remaining) more \(remaining == 1 ? "block" : "blocks")")
                    .font(Typography.ui(TypeScale.label))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(Theme.elevated)
    }
}
