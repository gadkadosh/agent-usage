import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @StateObject private var usage = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(
                snapshot: usage.snapshot,
                error: usage.error,
                isRefreshing: usage.isRefreshing,
                onRefresh: { Task { await usage.refresh() } },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            Label(usage.summary, systemImage: "chart.bar")
                .onAppear { usage.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
