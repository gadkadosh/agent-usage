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
        polling = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.refresh()
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
    }

    func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
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
