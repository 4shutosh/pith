import AppKit
import Foundation
import PithCore
import PithMacCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var settings: AppSettings = .shared
    @Binding var showSearch: Bool
    @Binding var showSidebar: Bool
    @Binding var sidebarCompact: Bool
    @Binding var sidebarPeek: Bool
    @Binding var themeMode: ThemeMode
    @State private var isPeeking = false
    @State private var trafficLightCenterY: CGFloat = 16
    @State private var peekZones: Set<PeekZone> = []
    @StateObject private var keyRouter: KeyRouter
    private let monitorSystemEvents: Bool
    @State private var focusBeforePalette: String?
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    init(
        controller: OutlinerController,
        shortcuts: ShortcutStore,
        showSearch: Binding<Bool>,
        showSidebar: Binding<Bool>,
        sidebarCompact: Binding<Bool>,
        sidebarPeek: Binding<Bool>,
        themeMode: Binding<ThemeMode>,
        keyRouter: KeyRouter? = nil,
        monitorSystemEvents: Bool = true
    ) {
        self.controller = controller
        self.shortcuts = shortcuts
        self._showSearch = showSearch
        self._showSidebar = showSidebar
        self._sidebarCompact = sidebarCompact
        self._sidebarPeek = sidebarPeek
        self._themeMode = themeMode
        self._keyRouter = StateObject(wrappedValue: keyRouter ?? KeyRouter())
        self.monitorSystemEvents = monitorSystemEvents
    }

    private static let sidebarWidth = EditorLayout.sidebarWidth
    private static let minimumTopBarHeight: CGFloat = 32
    private static let titleBarControlsLeading: CGFloat = 78

    private enum PeekZone {
        case toggle
        case sidebar
    }

    private func topBar(compact: Bool, docked: Bool) -> some View {
        HStack(spacing: 2) {
            SidebarToggleButton(label: compact || !showSidebar ? "Show sidebar" : "Hide sidebar") {
                performer.perform(.toggleSidebar)
            }
            .onHover { if compact { peek(.toggle, $0) } }
            ThemeToggleButton(mode: $themeMode)
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.titleBarControlsLeading)
        .frame(height: topBarHeight)
        .frame(maxWidth: .infinity)
        .background(WindowChromeArea(trafficLightCenterY: $trafficLightCenterY))
        .background {
            Theme.canvas
                .opacity(docked ? 0 : 1)
        }
        .animation(Motion.drawer, value: docked)
    }

    private var topBarHeight: CGFloat {
        max(Self.minimumTopBarHeight, (trafficLightCenterY * 2).rounded())
    }

    private func peek(_ zone: PeekZone, _ inside: Bool) {
        if inside {
            peekZones.insert(zone)
            withAnimation(Motion.drawer) { isPeeking = true }
            return
        }
        peekZones.remove(zone)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if peekZones.isEmpty {
                withAnimation(Motion.drawer) { isPeeking = false }
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = !EditorLayout.sidebarDocks(windowWidth: proxy.size.width)
            let docked = showSidebar && !compact
            let sidebarShown = compact ? (isPeeking || sidebarPeek) : showSidebar
            let layout = EditorLayout.compute(windowWidth: proxy.size.width, sidebarOpen: docked)

            ZStack(alignment: .top) {
            ZStack(alignment: .topLeading) {
                Group {
                    if controller.listScreen == .allPages {
                        let directory = EditorLayout.compute(
                            windowWidth: proxy.size.width,
                            sidebarOpen: docked,
                            maximumWidth: EditorLayout.directoryWidth
                        )
                        PageListView(
                            controller: controller,
                            directory: controller.directory,
                            showSearch: $showSearch,
                            contentLeading: directory.leading,
                            contentWidth: directory.width
                        )
                    } else if controller.listScreen == .shortcuts {
                        let directory = EditorLayout.compute(
                            windowWidth: proxy.size.width,
                            sidebarOpen: docked,
                            maximumWidth: EditorLayout.directoryWidth
                        )
                        ShortcutsView(
                            shortcuts: shortcuts,
                            contentLeading: directory.leading,
                            contentWidth: directory.width
                        )
                    } else if controller.listScreen == .settings {
                        let directory = EditorLayout.compute(
                            windowWidth: proxy.size.width,
                            sidebarOpen: docked,
                            maximumWidth: EditorLayout.directoryWidth
                        )
                        SettingsView(
                            settings: settings,
                            themeMode: $themeMode,
                            todayTitle: controller.todayTitle,
                            contentLeading: directory.leading,
                            contentWidth: directory.width
                        )
                    } else {
                        OutlinerView(
                            controller: controller,
                            find: controller.find,
                            contentLeading: layout.leading,
                            contentWidth: layout.width
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)

                if compact && sidebarPeek {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Motion.drawer) { sidebarPeek = false }
                        }
                }


                HStack(spacing: 0) {
                    Sidebar(controller: controller, shortcuts: shortcuts, showSearch: $showSearch)
                        .padding(.top, topBarHeight)
                        .frame(width: Self.sidebarWidth)
                        .background(Theme.sidebar)
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1)
                }
                .compositingGroup()
                .shadow(color: compact && sidebarShown ? Theme.shadow : .clear, radius: 24, x: 8)
                .offset(x: sidebarShown ? 0 : -(Self.sidebarWidth + 1))
                .allowsHitTesting(sidebarShown)
                .onHover { if compact { peek(.sidebar, $0) } }

                if showSearch {
                    ZStack(alignment: .top) {
                        Theme.sidebar.opacity(0.55)
                            .ignoresSafeArea()
                            .onTapGesture { dismissPalette(restoreFocus: true) }
                            .transition(.opacity)

                        QuickSearchSheet(
                            controller: controller,
                            shortcuts: shortcuts,
                            search: controller.search,
                            isPresented: $showSearch,
                            layout: PaletteLayout(container: proxy.size),
                            onDismiss: { dismissPalette(restoreFocus: true) },
                            onCommand: { action in
                                focusBeforePalette = nil
                                performer.perform(action)
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.elevatedBorder, lineWidth: 1))
                        .shadow(color: Theme.shadow, radius: 28, y: 12)
                        .padding(.top, PaletteLayout.top)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                    .zIndex(10)
                }
            }
            topBar(compact: compact, docked: docked)
            }
            .overlay(alignment: .bottomTrailing) {
                TransferBanner(transfer: controller.transfer) {
                    controller.cancelTransfer()
                }
                .padding(16)
            }
            .animation(Motion.pop, value: showSearch)
            .onAppear { sidebarCompact = compact }
            .onChange(of: compact) { now in
                sidebarCompact = now
                isPeeking = false
                sidebarPeek = false
            }
            .onChange(of: controller.sidebarDestination) { _ in
                if sidebarPeek {
                    withAnimation(Motion.drawer) { sidebarPeek = false }
                }
            }
        }
        .keyScope(.global, whileEditingText: true) { handleGlobalKey($0) }
        .environmentObject(keyRouter)
        .background(Theme.canvas)
        .ignoresSafeArea()
        .onAppear {
            if monitorSystemEvents {
                keyRouter.startMonitoring()
            }
        }
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

    private var performer: ActionPerformer {
        ActionPerformer(controller: controller, showSidebar: $showSidebar, sidebarCompact: $sidebarCompact, sidebarPeek: $sidebarPeek, themeMode: $themeMode, showSearch: $showSearch)
    }

    private func handleGlobalKey(_ stroke: KeyStroke) -> Bool {
        guard let action = shortcuts.action(matching: stroke, in: .global), controller.isAvailable(action) else {
            return false
        }
        performer.perform(action)
        return true
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
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @State private var showSearch = false
    @State private var showSidebar = true
    @State private var sidebarCompact = false
    @State private var sidebarPeek = false
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
            let ctrl = try OutlinerController(
                graph: graph,
                shortcuts: ShortcutStore.shared,
                worker: try GraphWorker(path: dbPath),
                background: try GraphWorker(path: dbPath, qos: .utility)
            )
            _controller = StateObject(wrappedValue: ctrl)
        } catch {
            fatalError("Failed to open pith graph: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                controller: controller,
                shortcuts: shortcuts,
                showSearch: $showSearch,
                showSidebar: $showSidebar,
                sidebarCompact: $sidebarCompact,
                sidebarPeek: $sidebarPeek,
                themeMode: $themeMode
            )
                .frame(minWidth: EditorLayout.minimumWindowWidth, minHeight: EditorLayout.minimumWindowHeight)
                .preferredColorScheme(themeMode.colorScheme)
                .onAppear { NSApp.appearance = themeMode.appearance }
                .onChange(of: themeMode) { NSApp.appearance = $0.appearance }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(
                controller: controller,
                shortcuts: shortcuts,
                showSearch: $showSearch,
                showSidebar: $showSidebar,
                sidebarCompact: $sidebarCompact,
                sidebarPeek: $sidebarPeek,
                themeMode: $themeMode
            )
        }
    }
}

struct AppCommands: Commands {
    let controller: OutlinerController
    @ObservedObject var shortcuts: ShortcutStore
    @Binding var showSearch: Bool
    @Binding var showSidebar: Bool
    @Binding var sidebarCompact: Bool
    @Binding var sidebarPeek: Bool
    @Binding var themeMode: ThemeMode

    private var performer: ActionPerformer {
        ActionPerformer(controller: controller, showSidebar: $showSidebar, sidebarCompact: $sidebarCompact, sidebarPeek: $sidebarPeek, themeMode: $themeMode, showSearch: $showSearch)
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { controller.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { controller.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Button(AppAction.importLogseqGraph.title) { performer.perform(.importLogseqGraph) }
                .dynamicShortcut(.importLogseqGraph, in: shortcuts)
            Button(AppAction.exportMarkdown.title) { performer.perform(.exportMarkdown) }
                .dynamicShortcut(.exportMarkdown, in: shortcuts)
        }
        CommandMenu("Page") {
            menuItems(for: .page)
        }
        CommandMenu("Navigate") {
            menuItems(for: .navigation)
        }
        CommandGroup(after: .sidebar) {
            Picker("Appearance", selection: $themeMode) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            menuItems(for: .window)
        }
    }

    @ViewBuilder
    private func menuItems(for category: ShortcutCategory) -> some View {
        ForEach(AppAction.allCases.filter { $0.category == category && $0.scope == .global }) { action in
            Button(action.title) { performer.perform(action) }
                .dynamicShortcut(action, in: shortcuts)
        }
    }
}

extension View {
    @ViewBuilder
    func dynamicShortcut(_ action: AppAction, in store: ShortcutStore) -> some View {
        if let shortcut = store.combo(for: action)?.swiftUIShortcut {
            self.keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
