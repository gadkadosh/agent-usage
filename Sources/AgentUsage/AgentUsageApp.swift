import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @StateObject private var usage = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            Text(usage.details)
            if let error = usage.error {
                Text(error)
            }
            Divider()
            Button("Refresh") {
                Task { await usage.refresh() }
            }
            .disabled(usage.isRefreshing)
            Button("Quit Agent Usage") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label(usage.summary, systemImage: "chart.bar")
                .onAppear { usage.start() }
        }
    }
}

@MainActor
private final class UsageStore: ObservableObject {
    @Published private(set) var summary = "Agent Usage…"
    @Published private(set) var details = "Loading usage…"
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let limits = try await UsageClient.fetch()
            summary = limits.summary
            details = limits.details
            error = nil
        } catch {
            summary = "Usage unavailable"
            details = "Could not load usage."
            self.error = error.localizedDescription
        }
    }
}
