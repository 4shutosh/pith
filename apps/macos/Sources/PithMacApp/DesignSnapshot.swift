import AppKit
import PithCore
import PithMacCore
import SwiftUI

@MainActor
enum DesignSnapshot {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["PITH_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(
        controller: OutlinerController,
        showSidebar: Binding<Bool>,
        themeMode: Binding<ThemeMode>,
        showSearch: Binding<Bool>
    ) async {
        guard let directory = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        window.setContentSize(NSSize(width: 1280, height: 820))

        for mode in [ThemeMode.dark, .light] {
            themeMode.wrappedValue = mode
            showSidebar.wrappedValue = true
            controller.openTodayJournal()
            await capture(window, directory, "\(mode.rawValue)-1-journals")

            if let first = controller.rows.first {
                controller.focusBlock(first.id)
                await capture(window, directory, "\(mode.rawValue)-2-editing")
                controller.blurFocus()
            }

            if let page = controller.favoritePages.last {
                controller.selectPage(page.id)
                await capture(window, directory, "\(mode.rawValue)-3-page")
                if let row = controller.rows.first(where: \.hasChildren) {
                    controller.zoom(into: row.id)
                    await capture(window, directory, "\(mode.rawValue)-4-zoom")
                }
            }

            controller.showAllPages()
            await capture(window, directory, "\(mode.rawValue)-5-all-pages")

            controller.openTodayJournal()
            showSidebar.wrappedValue = false
            await capture(window, directory, "\(mode.rawValue)-6-sidebar-hidden")
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, _ directory: URL, _ name: String) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
