import AppKit
import SwiftUI

@main
enum AgentUsageEntry {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            DemoApp.main()
        } else {
            AgentUsageApp.main()
        }
    }
}

struct AgentUsageApp: App {
    @StateObject private var usage = UsageStore()
    @StateObject private var history = HistoryStore.live()

    var body: some Scene {
        MenuBarExtra {
            DashboardPanel(usage: usage, history: history)
        } label: {
            Label(usage.summary, systemImage: "chart.bar")
                .onAppear {
                    usage.start()
                    history.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct DemoApp: App {
    @StateObject private var usage: UsageStore
    @StateObject private var history: HistoryStore
    private let demo: DashboardDemo

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--demo")!
        let scenario = arguments.indices.contains(index + 1) ? arguments[index + 1] : "ready"
        let demo = DashboardDemo(scenario: scenario)
        self.demo = demo
        _usage = StateObject(wrappedValue: demo.makeUsageStore())
        _history = StateObject(wrappedValue: demo.makeHistoryStore())
    }

    var body: some Scene {
        WindowGroup("Agent Usage — Synthetic Demo") {
            DashboardPanel(usage: usage, history: history, referenceDate: demo.now).task {
                await usage.refresh()
                await history.refresh()
                if demo.isStale {
                    await usage.refresh()
                    await history.refresh()
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

struct DashboardPanel: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var history: HistoryStore
    var referenceDate: Date? = nil

    var body: some View {
        UsagePanel(
            snapshot: usage.snapshot,
            error: usage.error,
            isRefreshing: usage.isRefreshing || history.isRefreshing,
            history: history,
            referenceDate: referenceDate,
            onRefresh: {
                Task { await usage.refresh() }
                Task { await history.refresh() }
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }
}
