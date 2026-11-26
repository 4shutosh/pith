import PithMacCore
import SwiftUI

private final class KeyHandlerBox {
    var handler: (KeyStroke) -> Bool = { _ in false }
}

private struct KeyScopeModifier: ViewModifier {
    let layer: KeyLayer
    let whileEditingText: Bool
    let handler: (KeyStroke) -> Bool
    @EnvironmentObject private var keyRouter: KeyRouter
    @State private var box = KeyHandlerBox()
    @State private var registration: UUID?

    func body(content: Content) -> some View {
        box.handler = handler
        return content
            .onAppear {
                guard registration == nil else { return }
                let box = box
                registration = keyRouter.register(layer: layer, whileEditingText: whileEditingText) { box.handler($0) }
            }
            .onDisappear {
                if let registration {
                    keyRouter.unregister(registration)
                }
                registration = nil
            }
    }
}

extension View {
    func keyScope(
        _ layer: KeyLayer,
        whileEditingText: Bool = false,
        handler: @escaping (KeyStroke) -> Bool
    ) -> some View {
        modifier(KeyScopeModifier(layer: layer, whileEditingText: whileEditingText, handler: handler))
    }
}
