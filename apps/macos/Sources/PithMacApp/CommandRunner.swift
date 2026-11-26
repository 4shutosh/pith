import AppKit
import PithMacCore
import SwiftUI

@MainActor
enum CommandRunner {
    static func run(
        _ command: PaletteCommand,
        controller: OutlinerController,
        showSidebar: Binding<Bool>,
        themeMode: Binding<ThemeMode>
    ) {
        switch command {
        case .toggleSidebar:
            withAnimation(.easeOut(duration: 0.18)) {
                showSidebar.wrappedValue.toggle()
            }
        case .toggleTheme:
            themeMode.wrappedValue = ThemeMode.toggled(currentlyDark: ThemeMode.isDark(NSApp.effectiveAppearance))
        default:
            controller.perform(command)
        }
    }
}
