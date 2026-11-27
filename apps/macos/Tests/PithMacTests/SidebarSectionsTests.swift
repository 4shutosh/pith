import Foundation
import PithCore
import PithMacCore
import XCTest

@MainActor
final class SidebarSectionsTests: XCTestCase {
    private func freshStore() -> (SidebarStore, UserDefaults, String) {
        let suite = "pith.sidebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SidebarStore(defaults: defaults)
        return (store, defaults, suite)
    }

    private func page(
        id: String,
        title: String,
        journalDay: Int32? = nil,
        favorite: Bool = false,
        updatedAt: Int64 = 100
    ) -> FfiPage {
        FfiPage(
            id: id,
            title: title,
            journalDay: journalDay,
            documentMode: false,
            favorite: favorite,
            version: 1,
            updatedAt: updatedAt
        )
    }

    func testCreateRenameReorderCollapseAndDeleteSectionsPersistAcrossReload() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(store.createSection(title: "   "))

        let work = store.createSection(title: "  Work  ", initialPageId: "p1")
        let reading = store.createSection(title: "Reading")
        XCTAssertEqual(store.sections.map(\.title), ["Work", "Reading"])
        XCTAssertEqual(work?.pageIds, ["p1"])

        store.renameSection(reading!.id, to: "Books")
        store.toggleCollapsed(work!.id)
        store.moveSection(reading!.id, up: true)

        XCTAssertEqual(store.sections.map(\.title), ["Books", "Work"])
        XCTAssertEqual(store.sections[1].isCollapsed, true)

        let reloaded = SidebarStore(defaults: defaults)
        XCTAssertEqual(reloaded.sections.map(\.title), ["Books", "Work"])
        XCTAssertEqual(reloaded.sections[1].isCollapsed, true)
        XCTAssertEqual(reloaded.sections[1].pageIds, ["p1"])

        reloaded.deleteSection(work!.id)
        XCTAssertEqual(reloaded.sections.map(\.title), ["Books"])
    }

    func testAddRemoveDeduplicateAndResolveLivePagesOnly() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let projects = store.createSection(title: "Projects")!
        store.addPage("p1", to: projects.id)
        store.addPage("p2", to: projects.id)
        store.addPage("p1", to: projects.id)
        store.addPage("deleted", to: projects.id)

        XCTAssertEqual(store.sections[0].pageIds, ["p1", "p2", "deleted"])
        XCTAssertTrue(store.sectionContains(projects.id, pageId: "p2"))

        let all = [
            page(id: "p1", title: "Alpha"),
            page(id: "p2", title: "Beta"),
        ]
        XCTAssertEqual(store.pages(for: store.sections[0], from: all).map(\.title), ["Alpha", "Beta"])

        store.removePage("p1", from: projects.id)
        XCTAssertEqual(store.sections[0].pageIds, ["p2", "deleted"])
        XCTAssertFalse(store.sectionContains(projects.id, pageId: "p1"))
    }

    func testMergeSectionAppendsUniquePagesInOrderAndRemovesSource() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let target = store.createSection(title: "Active")!
        store.addPage("p1", to: target.id)
        store.addPage("p2", to: target.id)

        let source = store.createSection(title: "Inbox")!
        store.addPage("p2", to: source.id)
        store.addPage("p3", to: source.id)
        store.addPage("p4", to: source.id)

        store.mergeSection(source.id, into: source.id)
        XCTAssertEqual(store.sections.count, 2)

        store.mergeSection(source.id, into: target.id)
        XCTAssertEqual(store.sections.count, 1)
        XCTAssertEqual(store.sections[0].title, "Active")
        XCTAssertEqual(store.sections[0].pageIds, ["p1", "p2", "p3", "p4"])
    }

    func testRecentPagesExcludesJournalsFavoritesAndSectionPagesAndRespectsSettings() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let work = store.createSection(title: "Work", initialPageId: "sec1")!
        XCTAssertEqual(work.pageIds, ["sec1"])

        let all = [
            page(id: "j1", title: "2026-11-27", journalDay: 20261127, updatedAt: 500),
            page(id: "fav1", title: "Pinned", favorite: true, updatedAt: 400),
            page(id: "sec1", title: "In Section", updatedAt: 350),
            page(id: "r1", title: "Newest", updatedAt: 300),
            page(id: "r2", title: "Middle", updatedAt: 200),
            page(id: "r3", title: "Oldest", updatedAt: 100),
        ]

        store.recentLimit = 2
        XCTAssertEqual(store.recentPages(from: all).map(\.id), ["r1", "r2"])

        store.showRecent = false
        XCTAssertEqual(store.recentPages(from: all), [])

        store.resetPreferences()
        XCTAssertTrue(store.showRecent)
        XCTAssertEqual(store.recentLimit, 8)
        XCTAssertEqual(store.favoritesPreviewLimit, 8)
        XCTAssertEqual(store.recentPages(from: all).map(\.id), ["r1", "r2", "r3"])
    }
}
