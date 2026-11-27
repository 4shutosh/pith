import CoreGraphics

public enum AdaptiveColumns {
    public static func count(width: CGFloat, minimumColumnWidth: CGFloat, spacing: CGFloat, maximum: Int) -> Int {
        let fitting = Int(((width + spacing) / (minimumColumnWidth + spacing)).rounded(.down))
        return max(1, min(maximum, fitting))
    }
}
