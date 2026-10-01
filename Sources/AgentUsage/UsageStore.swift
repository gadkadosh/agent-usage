import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false

    var summary: String {
        snapshot?.limits.summary ?? (error == nil ? "Agent Usage…" : "Usage unavailable")
    }

    private let fetch: @Sendable () async throws -> UsageLimits
    private let now: () -> Date
    private var started = false

    init(
        fetch: @escaping @Sendable () async throws -> UsageLimits = UsageClient.fetch,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.now = now
    }

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
            let limits = try await fetch()
            snapshot = UsageSnapshot(limits: limits, fetchedAt: now())
            error = nil
        } catch {
            // Keep the last successful reading, clearly marked as stale in the panel.
            self.error = error.localizedDescription
        }
    }
}
