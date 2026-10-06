import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @StateObject private var usage = UsageStore()
    @StateObject private var history = HistoryStore.live()

    var body: some Scene {
        MenuBarExtra {
            DashboardPanel(usage: usage, history: history)
        } label: {
            Label(usage.summary, systemImage: "chart.bar")
                .onAppear { usage.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
