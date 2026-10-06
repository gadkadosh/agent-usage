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
    private let sleep: @Sendable (Duration) async throws -> Void
    private var polling: Task<Void, Never>?
    private var pollingID: UUID?
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        fetch: @escaping @Sendable () async throws -> HistorySnapshot,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.fetch = fetch
        self.sleep = sleep
    }

    /// The caller chooses the cadence; no production polling policy or discovery is wired here.
    func start(refreshInterval: Duration) {
        precondition(refreshInterval > .zero)
        guard polling == nil else { return }
        let sleep = self.sleep
        let id = UUID()
        pollingID = id
        polling = Task { [weak self] in
            defer {
                // An old task must not clear a newer poller's handle after stop/start.
                if self?.pollingID == id {
                    self?.polling = nil
                    self?.pollingID = nil
                }
            }
            while !Task.isCancelled, self != nil {
                await self?.refreshWhenIdle()
                do {
                    try Task.checkCancellation()
                    try await sleep(refreshInterval)
                } catch { break }
            }
        }
    }

    deinit { polling?.cancel() }

    func stop() {
        polling?.cancel()
        polling = nil
        pollingID = nil
    }

    /// Panel reopen and polling both wait for a cancelled/in-flight scan before fetching.
    func refreshWhenIdle() async {
        // A restarted poller must wait for the old fetch, not skip straight to sleeping.
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
