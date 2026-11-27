import Foundation
import PithCore

public struct SidebarSection: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var pageIds: [String]
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), title: String, pageIds: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.pageIds = pageIds
        self.isCollapsed = isCollapsed
    }
}

private struct SidebarStatePayload: Codable {
    var sections: [SidebarSection]
    var favoritesCollapsed: Bool
    var recentCollapsed: Bool
    var showRecent: Bool
    var recentLimit: Int
    var favoritesPreviewLimit: Int
}

@MainActor
public final class SidebarStore: ObservableObject {
    public static let shared = SidebarStore()

    @Published public private(set) var sections: [SidebarSection] = []
    @Published public var favoritesCollapsed: Bool = false { didSet { save() } }
    @Published public var recentCollapsed: Bool = false { didSet { save() } }
    @Published public var showRecent: Bool = true { didSet { save() } }
    @Published public var recentLimit: Int = 8 { didSet { save() } }
    @Published public var favoritesPreviewLimit: Int = 8 { didSet { save() } }

    private let defaults: UserDefaults
    private let storageKey: String
    private var isLoading = false

    public init(defaults: UserDefaults = .standard, storageKey: String = "pith.sidebar.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    public var allSectionPageIds: Set<String> {
        var ids = Set<String>()
        for section in sections {
            ids.formUnion(section.pageIds)
        }
        return ids
    }

    public func pages(for section: SidebarSection, from allPages: [FfiPage]) -> [FfiPage] {
        let byId = Dictionary(uniqueKeysWithValues: allPages.map { ($0.id, $0) })
        return section.pageIds.compactMap { byId[$0] }
    }

    public func pages(for section: SidebarSection, in library: PageLibrary) -> [FfiPage] {
        section.pageIds.compactMap { library[$0] }
    }

    public func recentPages(from allPages: [FfiPage]) -> [FfiPage] {
        guard showRecent else { return [] }
        let excluded = allSectionPageIds
        let candidates = allPages.filter { $0.journalDay == nil && !$0.favorite && !excluded.contains($0.id) }
        return PageLibrary.recent(candidates, limit: max(1, recentLimit))
    }

    public func recentPages(in library: PageLibrary) -> [FfiPage] {
        guard showRecent else { return [] }
        let excluded = allSectionPageIds
        let candidates = library.byId.values.filter { $0.journalDay == nil && !$0.favorite && !excluded.contains($0.id) }
        return PageLibrary.recent(candidates, limit: max(1, recentLimit))
    }

    @discardableResult
    public func createSection(title: String, initialPageId: String? = nil) -> SidebarSection? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let section = SidebarSection(
            title: trimmed,
            pageIds: initialPageId.map { [$0] } ?? []
        )
        sections.append(section)
        save()
        return section
    }

    public func renameSection(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].title = trimmed
        save()
    }

    public func deleteSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        save()
    }

    public func toggleCollapsed(_ id: UUID) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[idx].isCollapsed.toggle()
        save()
    }

    public func moveSection(_ id: UUID, up: Bool) {
        guard let idx = sections.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard sections.indices.contains(target) else { return }
        sections.swapAt(idx, target)
        save()
    }

    public func mergeSection(_ sourceId: UUID, into targetId: UUID) {
        guard sourceId != targetId,
              let sourceIdx = sections.firstIndex(where: { $0.id == sourceId }),
              let targetIdx = sections.firstIndex(where: { $0.id == targetId }) else { return }
        let incoming = sections[sourceIdx].pageIds
        var existing = Set(sections[targetIdx].pageIds)
        for pageId in incoming where existing.insert(pageId).inserted {
            sections[targetIdx].pageIds.append(pageId)
        }
        sections.remove(at: sourceIdx)
        save()
    }

    public func addPage(_ pageId: String, to sectionId: UUID) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        guard !sections[idx].pageIds.contains(pageId) else { return }
        sections[idx].pageIds.append(pageId)
        save()
    }

    public func removePage(_ pageId: String, from sectionId: UUID) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].pageIds.removeAll { $0 == pageId }
        save()
    }

    public func sectionContains(_ sectionId: UUID, pageId: String) -> Bool {
        sections.first(where: { $0.id == sectionId })?.pageIds.contains(pageId) == true
    }

    public func resetPreferences() {
        favoritesCollapsed = false
        recentCollapsed = false
        showRecent = true
        recentLimit = 8
        favoritesPreviewLimit = 8
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = defaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(SidebarStatePayload.self, from: data) else {
            return
        }
        sections = payload.sections
        favoritesCollapsed = payload.favoritesCollapsed
        recentCollapsed = payload.recentCollapsed
        showRecent = payload.showRecent
        recentLimit = payload.recentLimit
        favoritesPreviewLimit = payload.favoritesPreviewLimit
    }

    private func save() {
        guard !isLoading else { return }
        let payload = SidebarStatePayload(
            sections: sections,
            favoritesCollapsed: favoritesCollapsed,
            recentCollapsed: recentCollapsed,
            showRecent: showRecent,
            recentLimit: recentLimit,
            favoritesPreviewLimit: favoritesPreviewLimit
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
