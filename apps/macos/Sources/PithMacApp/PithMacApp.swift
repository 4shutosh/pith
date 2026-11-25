import AppKit
import Foundation
import PithCore
import SwiftUI

@MainActor
final class GraphModel: ObservableObject {
    @Published var pages: [FfiPage] = []
    @Published var selectedPageId: String?
    @Published var rows: [FfiFlatBlockRow] = []
    @Published var newBlockText: String = ""
    @Published var errorMessage: String?

    private let graph: PithGraph
    private var lastDataVersion: Int64 = 0
    private var lastSeq: Int64 = 0

    init() {
        let dbPath = ProcessInfo.processInfo.environment["PITH_DB"]
            ?? (NSHomeDirectory() + "/.pith/pith.db")
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        do {
            let opened = try PithGraph.open(path: dbPath)
            self.graph = opened
            let journal = try opened.getOrCreateJournal(date: nil, actor: "me")
            self.selectedPageId = journal.id
            self.lastDataVersion = try opened.dataVersion()
            let feed = try opened.changesSince(afterSeq: 0, limit: 100)
            self.lastSeq = feed.latestSeq
            self.reload()
        } catch {
            fatalError("Failed to open pith graph: \(error)")
        }
    }

    func reload() {
        do {
            pages = try graph.listPages()
            if let pageId = selectedPageId {
                let window = try graph.readPageWindow(pageId: pageId, offset: 0, limit: 500)
                rows = window.rows
            } else {
                rows = []
            }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func pollExternalChanges() {
        do {
            let currentVersion = try graph.dataVersion()
            if currentVersion != lastDataVersion {
                lastDataVersion = currentVersion
                let feed = try graph.changesSince(afterSeq: lastSeq, limit: 100)
                lastSeq = feed.latestSeq
                reload()
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func appendBlock() {
        let text = newBlockText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let pageId = selectedPageId else { return }
        do {
            let lastRootKey = rows.last(where: { $0.parentId == nil })?.orderKey
            let orderKey = try orderKeyBetween(lower: lastRootKey, upper: nil)
            let op = FfiOp.insertBlock(
                id: newId(),
                pageId: pageId,
                parentId: nil,
                orderKey: orderKey,
                content: text
            )
            let meta = FfiTxMeta(
                writer: .user,
                actor: "me",
                session: nil,
                summary: "append block"
            )
            _ = try graph.applyOps(ops: [op], meta: meta)
            newBlockText = ""
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func toggleCollapse(_ row: FfiFlatBlockRow) {
        do {
            let op = FfiOp.setCollapsed(id: row.id, collapsed: !row.collapsed)
            let meta = FfiTxMeta(
                writer: .user,
                actor: "me",
                session: nil,
                summary: "toggle collapse"
            )
            _ = try graph.applyOps(ops: [op], meta: meta)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func undo() {
        do {
            _ = try graph.undoLast(actor: "me", force: false)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func redo() {
        do {
            _ = try graph.redoLast(actor: "me", force: false)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = GraphModel()
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            List(model.pages, id: \.id, selection: $model.selectedPageId) { page in
                Text(page.title)
                    .tag(page.id)
            }
            .onChange(of: model.selectedPageId) { _ in
                model.reload()
            }
            .navigationTitle("Pages")
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Undo") { model.undo() }
                    Button("Redo") { model.redo() }
                    Spacer()
                    if let err = model.errorMessage {
                        Text(err).foregroundColor(.red)
                    }
                }
                .padding(.horizontal)

                List(model.rows, id: \.id) { row in
                    HStack(alignment: .top, spacing: 6) {
                        if row.hasChildren {
                            Button(row.collapsed ? "+" : "-") {
                                model.toggleCollapse(row)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("•")
                        }
                        Text(row.renderedContent)
                    }
                    .padding(.leading, CGFloat(row.depth) * 16)
                }

                HStack {
                    TextField("Add a bullet...", text: $model.newBlockText)
                        .onSubmit { model.appendBlock() }
                    Button("Add") { model.appendBlock() }
                }
                .padding()
            }
        }
        .onReceive(timer) { _ in
            model.pollExternalChanges()
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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
