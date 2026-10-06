import AppKit
import SwiftUI

struct DashboardPanel: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        UsagePanel(
            snapshot: usage.snapshot,
            error: usage.error,
            isRefreshing: usage.isRefreshing,
            history: history,
            onRefresh: { Task { await refresh() } },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        // No history startup timer. A manual request may finish after the panel closes.
        .background(HistoryPanelLifecycle(history: history).frame(width: 0, height: 0))
    }

    func refresh() async {
        async let allowance: Void = usage.refresh()
        async let local: Void = history.refresh()
        _ = await (allowance, local)
    }
}
