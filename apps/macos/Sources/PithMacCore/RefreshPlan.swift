import PithCore

public struct RefreshPlan: Equatable {
    public var reloadAll: Bool = false
    public var reloadPageLists: Bool = false
    public var reloadVisible: Bool = false
    public var patchRows: [String] = []
    public var touchesOtherPages: Bool = false

    public init(
        reloadAll: Bool = false,
        reloadPageLists: Bool = false,
        reloadVisible: Bool = false,
        patchRows: [String] = [],
        touchesOtherPages: Bool = false
    ) {
        self.reloadAll = reloadAll
        self.reloadPageLists = reloadPageLists
        self.reloadVisible = reloadVisible
        self.patchRows = patchRows
        self.touchesOtherPages = touchesOtherPages
    }

    public var changesVisibleRows: Bool {
        reloadAll || reloadVisible || !patchRows.isEmpty
    }

    public var isEmpty: Bool {
        self == RefreshPlan()
    }

    public static func make(_ changes: FfiGraphChanges, visiblePages: Set<String>, loadedRows: Set<String>) -> RefreshPlan {
        if changes.reloadAll {
            return RefreshPlan(reloadAll: true, reloadPageLists: true, reloadVisible: true, touchesOtherPages: true)
        }
        let restructured = Set(changes.restructuredPages)
        let reloadVisible = !restructured.isDisjoint(with: visiblePages)
        return RefreshPlan(
            reloadPageLists: !changes.pages.isEmpty,
            reloadVisible: reloadVisible,
            patchRows: reloadVisible ? [] : changes.staleBlocks.filter(loadedRows.contains),
            touchesOtherPages: !changes.pages.isEmpty
                || !restructured.isSubset(of: visiblePages)
                || changes.staleBlocks.contains { !loadedRows.contains($0) }
        )
    }
}
