import AppKit
import SwiftUI

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                cursor.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}
