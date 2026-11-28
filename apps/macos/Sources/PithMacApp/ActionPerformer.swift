import AppKit
import PithMacCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ActionPerformer {
    let controller: OutlinerController
    let showSidebar: Binding<Bool>
    let sidebarCompact: Binding<Bool>
    let sidebarPeek: Binding<Bool>
    let themeMode: Binding<ThemeMode>
    let showSearch: Binding<Bool>

    func perform(_ action: AppAction) {
        switch action {
        case .openPalette:
            openPalette(.everything)
            return
        case .searchShortcuts:
            openPalette(.shortcuts)
            return
        default:
            break
        }
        if showSearch.wrappedValue {
            withAnimation(Motion.fast) { showSearch.wrappedValue = false }
        }
        switch action {
        case .toggleSidebar:
            withAnimation(Motion.drawer) {
                if sidebarCompact.wrappedValue {
                    sidebarPeek.wrappedValue.toggle()
                } else {
                    showSidebar.wrappedValue.toggle()
                }
            }
        case .toggleTheme:
            themeMode.wrappedValue = ThemeMode.toggled(currentlyDark: ThemeMode.isDark(NSApp.effectiveAppearance))
        case .importLogseqGraph:
            pickLogseqExport()
        case .exportMarkdown:
            pickExportDirectory()
        default:
            controller.perform(action)
        }
    }

    private func pickLogseqExport() {
        let panel = NSOpenPanel()
        panel.title = "Import Logseq Graph"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let sqliteType = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqliteType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            controller.startLogseqImport(sourcePath: url.path)
        }
    }

    private func pickExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Export as Markdown"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.startMarkdownExport(outDir: url.path)
        }
    }

    private func openPalette(_ scope: PaletteScope) {
        if showSearch.wrappedValue && controller.search.scope == scope {
            withAnimation(Motion.fast) { showSearch.wrappedValue = false }
            return
        }
        controller.search.scope = scope
        withAnimation(Motion.pop) { showSearch.wrappedValue = true }
    }
}
