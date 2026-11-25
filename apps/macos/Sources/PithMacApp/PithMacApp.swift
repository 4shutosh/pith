import AppKit
import Foundation
import PithCore
import PithMacCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OutlinerController
    @Binding var showSearch: Bool
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(controller: controller, showSearch: $showSearch)
                .frame(width: 244)

            Group {
                if controller.isShowingAllPages {
                    AllPagesView(controller: controller)
                } else {
                    OutlinerView(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder, lineWidth: 1))
            .padding(.top, 8)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .sheet(isPresented: $showSearch) {
            QuickSearchSheet(controller: controller, isPresented: $showSearch)
        }
        .onReceive(timer) { _ in
            controller.pollExternalChanges()
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
            ContentView(controller: controller, showSearch: $showSearch)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
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
            }
        }
    }
}
