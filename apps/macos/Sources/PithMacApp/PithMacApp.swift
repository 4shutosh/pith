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
        NavigationSplitView {
            List(selection: Binding(
                get: { controller.selectedPageId },
                set: { newId in
                    if let id = newId {
                        controller.selectPage(id)
                    }
                }
            )) {
                Section("Quick") {
                    Button {
                        controller.openTodayJournal()
                    } label: {
                        Label("Today's Journal", systemImage: "calendar")
                    }
                    .buttonStyle(.plain)

                    Button {
                        showSearch = true
                    } label: {
                        Label("Search (⌘K)", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }

                Section("Pages (\(controller.pages.count))") {
                    ForEach(controller.pages, id: \.id) { page in
                        Label(
                            page.title,
                            systemImage: page.journalDay != nil ? "calendar.day.timeline.left" : "doc.text"
                        )
                        .tag(page.id)
                    }
                }
            }
            .navigationTitle("pith")
        } detail: {
            OutlinerView(controller: controller)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            controller.undo()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        Button {
                            controller.redo()
                        } label: {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                        }
                        Button {
                            showSearch = true
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                }
        }
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
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    controller.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    controller.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Quick Search") {
                    showSearch = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Today's Journal") {
                    controller.openTodayJournal()
                }
                .keyboardShortcut("j", modifiers: .command)
            }
        }
    }
}
