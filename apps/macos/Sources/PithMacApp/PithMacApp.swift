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
    @StateObject private var keyRouter = KeyRouter()
    @State private var focusBeforePalette: String?
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private static let sidebarWidth = EditorLayout.sidebarWidth
    private static let trafficLightCenterY: CGFloat = 16
    private static let titleBarControlsLeading: CGFloat = 78

    var body: some View {
        GeometryReader { proxy in
            let layout = EditorLayout.compute(windowWidth: proxy.size.width, sidebarOpen: showSidebar)

            ZStack(alignment: .topLeading) {
                Group {
                    if controller.listScreen == .allPages {
                        let directory = EditorLayout.compute(
                            windowWidth: proxy.size.width,
                            sidebarOpen: showSidebar,
                            maximumWidth: EditorLayout.directoryWidth
                        )
                        PageListView(
                            controller: controller,
                            showSearch: $showSearch,
                            contentLeading: directory.leading,
                            contentWidth: directory.width
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

                HStack(spacing: 2) {
                    SidebarToggleButton(label: showSidebar ? "Hide sidebar" : "Show sidebar") {
                        withAnimation(Motion.drawer) {
                            showSidebar.toggle()
                        }
                    }
                    ThemeToggleButton(mode: $themeMode)
                }
                .padding(.leading, Self.titleBarControlsLeading)
                .padding(.top, Self.trafficLightCenterY - 14)

                if showSearch {
                    ZStack(alignment: .top) {
                        Theme.sidebar.opacity(0.55)
                            .ignoresSafeArea()
                            .onTapGesture { dismissPalette(restoreFocus: true) }
                            .transition(.opacity)

                        QuickSearchSheet(
                            controller: controller,
                            isPresented: $showSearch,
                            onDismiss: { dismissPalette(restoreFocus: true) },
                            onCommand: { command in
                                focusBeforePalette = nil
                                CommandRunner.run(command, controller: controller, showSidebar: $showSidebar, themeMode: $themeMode)
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.elevatedBorder, lineWidth: 1))
                        .shadow(color: Theme.shadow, radius: 28, y: 12)
                        .padding(.top, 84)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                    .zIndex(10)
                }
            }
            .animation(Motion.pop, value: showSearch)
        }
        .environmentObject(keyRouter)
        .background(Theme.canvas)
        .ignoresSafeArea()
        .onAppear { keyRouter.startMonitoring() }
        .onDisappear { keyRouter.stopMonitoring() }
        .onChange(of: showSearch) { open in
            if open {
                focusBeforePalette = controller.focusedBlockId
            }
        }
        .onReceive(timer) { _ in
            controller.pollExternalChanges()
        }
        .confirmationDialog(
            "Delete page “\(controller.pendingPageDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { controller.pendingPageDelete != nil },
                set: { if !$0 { controller.pendingPageDelete = nil } }
            )
        ) {
            Button("Delete Page", role: .destructive) { controller.confirmPendingDelete() }
            Button("Cancel", role: .cancel) { controller.pendingPageDelete = nil }
        } message: {
            Text("You can undo this with ⌘Z.")
        }
        .confirmationDialog(
            "Restore deleted page “\(controller.pendingPageRestore?.title ?? "")”?",
            isPresented: Binding(
                get: { controller.pendingPageRestore != nil },
                set: { if !$0 { controller.pendingPageRestore = nil } }
            )
        ) {
            Button("Restore & Open") { controller.confirmPendingRestore() }
            Button("Cancel", role: .cancel) { controller.pendingPageRestore = nil }
        } message: {
            Text("Restores the page and its blocks. You can undo this with ⌘Z.")
        }
        .task {
            await DesignSnapshot.run(
                controller: controller,
                showSidebar: $showSidebar,
                themeMode: $themeMode,
                showSearch: $showSearch
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            controller.flushDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.flushDraft()
        }
    }

    private func dismissPalette(restoreFocus: Bool) {
        let previous = focusBeforePalette
        focusBeforePalette = nil
        withAnimation(Motion.fast) {
            showSearch = false
        }
        if restoreFocus, let previous {
            DispatchQueue.main.async {
                controller.focusBlock(previous)
            }
        }
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
            CommandMenu("Page") {
                Button("Find in Page…") { controller.perform(.findInPage) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!controller.isAvailable(.findInPage))
                Divider()
                Button("Expand All Blocks") { controller.perform(.expandAll) }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    .disabled(!controller.isAvailable(.expandAll))
                Button("Collapse All Blocks") { controller.perform(.collapseAll) }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!controller.isAvailable(.collapseAll))
                Divider()
                Button(controller.currentPage?.favorite == true ? "Remove from Favorites" : "Add to Favorites") {
                    controller.perform(.toggleFavorite)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!controller.isAvailable(.toggleFavorite))
                Button("Rename Page") { controller.perform(.renamePage) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!controller.isAvailable(.renamePage))
                Divider()
                Button("Delete Page…") { controller.perform(.deletePage) }
                    .disabled(!controller.isAvailable(.deletePage))
            }
            CommandMenu("Navigate") {
                Button("Search") {
                    withAnimation(Motion.pop) { showSearch.toggle() }
                }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Journals") { controller.openTodayJournal() }
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
                Button("Previous Day") { controller.perform(.previousDay) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!controller.isAvailable(.previousDay))
                Button("Next Day") { controller.perform(.nextDay) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!controller.isAvailable(.nextDay))
                Divider()
                Button(showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(Motion.drawer) {
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
