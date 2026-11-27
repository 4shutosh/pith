import PithCore

public enum PreviewWording {
    public static func title(_ preview: FfiLinkPreview) -> String {
        preview.deleted && preview.title.isEmpty ? "Deleted block" : preview.title
    }

    public static func subtitle(_ preview: FfiLinkPreview) -> String? {
        if preview.deleted {
            return preview.title.isEmpty ? nil : "Deleted · click the link to restore"
        }
        if !preview.parentPath.isEmpty {
            return preview.parentPath.joined(separator: " › ")
        }
        let blocks = count(preview.totalBlocks, "block")
        switch (preview.totalBlocks, preview.backlinkCount) {
        case (0, 0):
            return "Empty page"
        case (_, 0):
            return blocks
        default:
            return "\(blocks) · \(count(preview.backlinkCount, "backlink"))"
        }
    }

    private static func count(_ value: UInt64, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }
}
