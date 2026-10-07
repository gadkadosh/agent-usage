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
        DashboardScrollView(
            content: VStack(alignment: .leading, spacing: 18) {
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
        )
    }

    func refresh() async {
        async let allowance: Void = usage.refresh()
        async let local: Void = history.refresh()
        _ = await (allowance, local)
    }
}

private struct DashboardScrollView<Content: View>: View {
    let content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    contentHeight = height
                }
        }
        // Give MenuBarExtra an explicit ideal size, fitted to content until it needs to scroll.
        .frame(width: 360, height: min(contentHeight ?? maximumHeight, maximumHeight))
        .fixedSize(horizontal: true, vertical: true)
    }

    private var maximumHeight: CGFloat {
        max(240, min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
    }
}
