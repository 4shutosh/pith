import PithCore

public struct BacklinkGroup: Equatable {
    public let pageId: String
    public let pageTitle: String
    public let backlinks: [FfiBacklink]
}

public enum BacklinkGroups {
    public static func group(_ backlinks: [FfiBacklink]) -> [BacklinkGroup] {
        var order: [String] = []
        var byPage: [String: [FfiBacklink]] = [:]
        for backlink in backlinks {
            if byPage[backlink.pageId] == nil {
                order.append(backlink.pageId)
            }
            byPage[backlink.pageId, default: []].append(backlink)
        }
        return order.compactMap { pageId in
            guard let items = byPage[pageId], let first = items.first else { return nil }
            return BacklinkGroup(pageId: pageId, pageTitle: first.pageTitle, backlinks: items)
        }
    }
}
