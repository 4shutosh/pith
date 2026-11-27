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

            controller.showShortcuts()
            await capture(window, directory, "\(mode.rawValue)-7-shortcuts")
            scrollLongestToBottom(in: window)
            await capture(window, directory, "\(mode.rawValue)-8-shortcuts-scrolled")

            controller.showSettings()
            await capture(window, directory, "\(mode.rawValue)-9-settings")

            controller.createNewBlankPage()
            await capture(window, directory, "\(mode.rawValue)-10-new-page")

            controller.openTodayJournal()
            showSidebar.wrappedValue = false
            await capture(window, directory, "\(mode.rawValue)-6-sidebar-hidden")
        }
        NSApp.terminate(nil)
    }

    private static func scrollLongestToBottom(in window: NSWindow) {
        guard let root = window.contentView else { return }
        var scrollViews: [NSScrollView] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            if let scroll = view as? NSScrollView {
                scrollViews.append(scroll)
            }
            queue.append(contentsOf: view.subviews)
        }
        guard let longest = scrollViews.max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }), let document = longest.documentView else { return }
        let bottom = max(0, document.frame.height - longest.contentView.bounds.height)
        longest.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
        longest.reflectScrolledClipView(longest.contentView)
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
