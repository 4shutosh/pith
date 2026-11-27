import Foundation
import PithCore

public struct PageLibrary: Equatable {
    public static let recentLimit = 8

    public private(set) var byId: [String: FfiPage] = [:]
    public private(set) var favorites: [FfiPage] = []
    public private(set) var recents: [FfiPage] = []

    public init(_ pages: [FfiPage] = []) {
        byId = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        derive()
    }

    public var count: Int {
        byId.count
    }

    public subscript(id: String) -> FfiPage? {
        byId[id]
    }

    public func contains(where predicate: (FfiPage) -> Bool) -> Bool {
        byId.values.contains(where: predicate)
    }

    public mutating func apply(upserts: [FfiPage], removals: [String]) {
        for page in upserts {
            byId[page.id] = page
        }
        for id in removals {
            byId.removeValue(forKey: id)
        }
        derive()
    }

    public static func recent(_ pages: [FfiPage], limit: Int) -> [FfiPage] {
        Array(
            pages
                .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }
                .prefix(limit)
        )
    }

    private mutating func derive() {
        favorites = byId.values
            .filter(\.favorite)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        recents = Self.recent(byId.values.filter { $0.journalDay == nil && !$0.favorite }, limit: Self.recentLimit)
    }
}
