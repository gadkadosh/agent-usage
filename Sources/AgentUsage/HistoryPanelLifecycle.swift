import AppKit
import SwiftUI

/// MenuBarExtra retains its content while closed, so SwiftUI .task/.onAppear alone
/// do not represent subsequent opens. Observe only this panel's native window.
struct HistoryPanelLifecycle: NSViewRepresentable {
    let history: HistoryStore

    func makeNSView(context: Context) -> TrackingView { TrackingView(history: history) }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    @MainActor
    final class TrackingView: NSView {
        private let history: HistoryStore
        private var visible = false
        private var scan: Task<Void, Never>?

        init(history: HistoryStore) {
            self.history = history
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Not used with storyboards") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(visibilityChanged),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            visibilityChanged()
        }

        @objc private func visibilityChanged() {
            setVisible(window?.occlusionState.contains(.visible) == true)
        }

        func setVisible(_ value: Bool) {
            guard value != visible else { return }
            visible = value
            scan?.cancel()
            let history = self.history
            scan = value ? Task { await history.refreshWhenIdle() } : nil
        }

        deinit {
            scan?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
