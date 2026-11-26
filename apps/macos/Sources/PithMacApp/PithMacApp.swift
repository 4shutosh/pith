import AppKit
import Foundation
import PithCore
import PithMacCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool
    @Binding var showSidebar: Bool
    @Binding var themeMode: ThemeMode
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private static let sidebarWidth: CGFloat = 216

    var body: some View {
        GeometryReader { proxy in
            let layout = editorLayout(windowWidth: proxy.size.width, sidebarOpen: showSidebar)

            ZStack(alignment: .leading) {
                Group {
                    if controller.isShowingAllPages {
                        AllPagesView(
                            controller: controller,
                            contentLeading: layout.leading,
                            contentWidth: layout.width
                        )
                    } else {
                        OutlinerView(
                            controller: controller,
                            contentLeading: layout.leading,
                            contentWidth: layout.width
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)

                HStack(spacing: 0) {
                    Sidebar(controller: controller, showSearch: $showSearch)
                        .frame(width: Self.sidebarWidth)
                        .background(Theme.sidebar)
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1)
                }
                .offset(x: showSidebar ? 0 : -(Self.sidebarWidth + 1))
                .allowsHitTesting(showSidebar)

                VStack {
                    Spacer()
                    HStack {
                        SidebarToggleButton(label: showSidebar ? "Hide sidebar" : "Show sidebar") {
                            withAnimation(.easeOut(duration: 0.18)) {
                                showSidebar.toggle()
                            }
                        }
                        ThemeToggleButton(mode: $themeMode)
                        Spacer()
                    }
                    .padding(.leading, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .sheet(isPresented: $showSearch) {
            QuickSearchSheet(controller: controller, isPresented: $showSearch)
        }
        .onReceive(timer) { _ in
            controller.pollExternalChanges()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            controller.flushDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.flushDraft()
        }
    }

    private func editorLayout(windowWidth: CGFloat, sidebarOpen: Bool) -> (leading: CGFloat, width: CGFloat) {
        let sidebar: CGFloat = sidebarOpen ? Self.sidebarWidth : 0
        let available = max(320, windowWidth - sidebar)
        let width = min(680, max(320, available - 72))
        let centered = (windowWidth - width) / 2
        let leading = max(centered, sidebar + 36)
        return (leading, width)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PithMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller: OutlinerController
    @State private var showSearch = false
    @State private var showSidebar = true
    @AppStorage("pith.theme") private var themeMode: ThemeMode = .system

    init() {
        Typography.registerBundledFonts()
        let dbPath = ProcessInfo.processInfo.environment["PITH_DB"]
            ?? (NSHomeDirectory() + "/.pith/pith.db")
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        do {
            let graph = try PithGraph.open(path: dbPath)
            let ctrl = try OutlinerController(graph: graph)
            _controller = StateObject(wrappedValue: ctrl)
        } catch {
            fatalError("Failed to open pith graph: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, showSearch: $showSearch, showSidebar: $showSidebar, themeMode: $themeMode)
                .frame(minWidth: 820, minHeight: 540)
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear { NSApp.appearance = themeMode.appearance }
                .onChange(of: themeMode) { NSApp.appearance = $0.appearance }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { controller.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { controller.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Search") { showSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Today") { controller.openTodayJournal() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("All pages") { controller.showAllPages() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Back") { controller.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!controller.canGoBack && controller.zoomedBlockId == nil)
                Button("Forward") { controller.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!controller.canGoForward)
                Divider()
                Button("Previous Day") { controller.stepJournalDay(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next Day") { controller.stepJournalDay(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button(showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        showSidebar.toggle()
                    }
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: $themeMode) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Button("Toggle Light/Dark") {
                    themeMode = ThemeMode.toggled(currentlyDark: ThemeMode.isDark(NSApp.effectiveAppearance))
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
