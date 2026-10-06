import AppKit
import SwiftUI

/// Shared layout and refresh/visibility coordination; each source owns its presentation.
struct DashboardPanel: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var history: HistoryStore
    var referenceDate: Date? = nil

    var body: some View {
        content
            // No history startup timer. A manual request may finish after the panel closes.
            .background(HistoryPanelLifecycle(history: history).frame(width: 0, height: 0))
    }

    /// The same layout can be rendered without activating native-window scans.
    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DashboardHeader(
                    isRefreshing: usage.isRefreshing || history.isRefreshing,
                    onRefresh: { Task { await refresh() } },
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
                Divider()
                UsagePanel(
                    snapshot: usage.snapshot,
                    error: usage.error,
                    isRefreshing: usage.isRefreshing,
                    referenceDate: referenceDate
                )
                Divider()
                HistoryPanel(history: history)
            }
            .padding(20)
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        // A stable, bounded viewport avoids MenuBarExtra's tiny ScrollView ideal size.
        // Error messages and expanded details scroll rather than resizing the popover.
        .frame(width: 360, height: panelHeight)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var panelHeight: CGFloat {
        max(240, min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
    }

    func refresh() async {
        async let allowance: Void = usage.refresh()
        async let local: Void = history.refresh()
        _ = await (allowance, local)
    }
}
