import AppKit
import SwiftUI

/// MenuBarExtra grows its retained window automatically, but does not shrink it.
/// Keep the native frame aligned with the already bounded SwiftUI viewport.
struct DashboardWindowSize: NSViewRepresentable {
    let size: CGSize
    var onScreenHeightChange: (CGFloat) -> Void = { _ in }

    // Leave breathing room below the menu bar and above the visible screen's bottom edge.
    static func maximumHeight(for visibleHeight: CGFloat) -> CGFloat {
        max(1, visibleHeight - 40)
    }

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.onScreenHeightChange = onScreenHeightChange
        view.contentSize = size
    }

    @MainActor
    final class SizingView: NSView {
        var contentSize: CGSize = .zero {
            didSet { scheduleResize() }
        }
        var onScreenHeightChange: (CGFloat) -> Void = { _ in }
        private var resizeScheduled = false
        private var screenHeight: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(screenChanged),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(screenChanged),
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            }
            scheduleResize()
        }

        @objc private func screenChanged() { scheduleResize() }

        private func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            // Resize after SwiftUI has finished the current layout, not inside it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                guard let window = self.window else { return }
                let height = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
                if self.screenHeight != height {
                    self.screenHeight = height
                    self.onScreenHeightChange(height)
                }
                guard self.contentSize.width > 0, self.contentSize.height > 0 else { return }
                let size = CGSize(
                    width: ceil(self.contentSize.width),
                    height: ceil(self.contentSize.height)
                )
                guard window.contentRect(forFrameRect: window.frame).size != size else { return }
                var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
                frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}
