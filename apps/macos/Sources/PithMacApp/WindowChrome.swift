import AppKit
import SwiftUI

struct WindowChromeArea: NSViewRepresentable {
    @Binding var trafficLightCenterY: CGFloat

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.onTrafficLightCenter = { center in
            if abs(trafficLightCenterY - center) > 0.5 {
                trafficLightCenterY = center
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {}
}

final class WindowChromeView: NSView {
    var onTrafficLightCenter: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            performSystemDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportTrafficLights()
    }

    override func layout() {
        super.layout()
        reportTrafficLights()
    }

    private func reportTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview else { return }
        let frame = container.convert(close.frame, to: nil)
        let centerFromTop = window.frame.height - frame.midY
        DispatchQueue.main.async { [weak self] in
            self?.onTrafficLightCenter?(centerFromTop)
        }
    }

    private func performSystemDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }
}
