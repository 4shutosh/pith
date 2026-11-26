import PithCore

public enum TrailItem: Equatable {
    case crumb(FfiCrumb)
    case hidden([FfiCrumb])
}

public enum ZoomTrail {
    public static func items(_ breadcrumb: [FfiCrumb], maxVisible: Int) -> [TrailItem] {
        let ancestors = Array(breadcrumb.dropLast())
        guard ancestors.count > maxVisible, maxVisible >= 2 else {
            return ancestors.map(TrailItem.crumb)
        }
        let tail = ancestors.suffix(maxVisible - 1)
        let hidden = Array(ancestors[1..<(ancestors.count - tail.count)])
        return [.crumb(ancestors[0]), .hidden(hidden)] + tail.map(TrailItem.crumb)
    }
}
