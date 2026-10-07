import Foundation
import SwiftUI

/// Presentation-ready history state, independent of allowance authentication and refreshes.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published var period: HistoryPeriod = .today

    var summary: PeriodSummary? { snapshot?.summaries[period] }

    private let fetch: @Sendable () async throws -> HistorySnapshot
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(fetch: @escaping @Sendable () async throws -> HistorySnapshot) {
        self.fetch = fetch
    }

    /// Panel reopen waits for a cancelled/in-flight scan before fetching.
    func refreshWhenIdle() async {
        while isRefreshing, !Task.isCancelled {
            await withCheckedContinuation { refreshWaiters.append($0) }
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            snapshot = result
            error = nil
        } catch is CancellationError {
            // Cancellation is not a source failure; keep the previous snapshot and error.
        } catch {
            guard !Task.isCancelled else { return }
            // Never forward IO/decoder errors containing sensitive paths or payloads.
            // In particular, failed enumeration must not replace the last reading with zero.
            self.error = HistoryReadError.unavailable.localizedDescription
        }
    }
}
