import AppKit
import PithMacCore
import SwiftUI

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
        default:
            controller.perform(action)
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
