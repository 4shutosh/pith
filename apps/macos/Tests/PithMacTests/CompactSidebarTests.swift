import PithCore
@testable import PithMacApp
import PithMacCore
import SwiftUI
import XCTest

@MainActor
final class CompactSidebarTests: XCTestCase {
    private func performer(_ controller: OutlinerController, sidebar: Binding<Bool>, peek: Binding<Bool>, compact: Bool) -> ActionPerformer {
        ActionPerformer(
            controller: controller,
            showSidebar: sidebar,
            sidebarCompact: .constant(compact),
            sidebarPeek: peek,
            themeMode: .constant(.light),
            showSearch: .constant(false)
        )
    }

    func testToggleSidebarPeeksWhenNarrowAndDocksWhenWide() throws {
        let controller = try OutlinerController(graph: try PithGraph.openInMemory())
        var open = true
        var peek = false
        let sidebar = Binding(get: { open }, set: { open = $0 })
        let peeking = Binding(get: { peek }, set: { peek = $0 })

        performer(controller, sidebar: sidebar, peek: peeking, compact: true).perform(.toggleSidebar)
        XCTAssertTrue(open)
        XCTAssertTrue(peek)
        performer(controller, sidebar: sidebar, peek: peeking, compact: true).perform(.toggleSidebar)
        XCTAssertFalse(peek)

        performer(controller, sidebar: sidebar, peek: peeking, compact: false).perform(.toggleSidebar)
        XCTAssertFalse(open)
        XCTAssertFalse(peek)
    }
}
