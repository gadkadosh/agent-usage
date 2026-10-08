import AppKit
import SwiftUI

/// MenuBarExtra grows its retained window automatically, but does not shrink it.
/// Keep the native frame aligned with the already bounded SwiftUI viewport.
struct DashboardWindowSize: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.contentSize = size
    }

    @MainActor
    final class SizingView: NSView {
        var contentSize: CGSize = .zero {
            didSet { scheduleResize() }
        }
        private var resizeScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleResize()
        }

        private func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            // Resize after SwiftUI has finished the current layout, not inside it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                guard let window = self.window,
                    self.contentSize.width > 0, self.contentSize.height > 0
                else { return }
                let size = CGSize(
                    width: ceil(self.contentSize.width), height: ceil(self.contentSize.height))
                guard window.contentRect(forFrameRect: window.frame).size != size else { return }
                var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
                frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}
