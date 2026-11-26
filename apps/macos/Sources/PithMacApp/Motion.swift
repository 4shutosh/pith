import AppKit
import SwiftUI

enum Motion {
    static var hover: Animation? { gated(.easeOut(duration: 0.10)) }
    static var fast: Animation? { gated(.easeOut(duration: 0.12)) }
    static var morph: Animation? { gated(.spring(response: 0.20, dampingFraction: 0.88)) }
    static var drawer: Animation? { gated(.spring(response: 0.22, dampingFraction: 0.92)) }
    static var pop: Animation? { gated(.spring(response: 0.16, dampingFraction: 0.78)) }

    private static func gated(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }
}

struct PressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? scale : 1)
            .animation(reduceMotion ? nil : Motion.hover, value: configuration.isPressed)
    }
}
