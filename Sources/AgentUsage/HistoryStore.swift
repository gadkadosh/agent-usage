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
    private var scan: Task<Void, Never>?
    private var started = false

    init(fetch: @escaping @Sendable () async throws -> HistorySnapshot) {
        self.fetch = fetch
    }

    /// Launch once without awaiting IO. The store, not the panel, owns the scan.
    func start() {
        guard !started else { return }
        started = true
        _ = beginRefresh()
    }

    /// Join existing work. Closing a panel or cancelling a caller does not cancel indexing.
    func refresh() async {
        guard !Task.isCancelled else { return }
        await beginRefresh().value
    }

    private func beginRefresh() -> Task<Void, Never> {
        if let scan { return scan }
        isRefreshing = true
        let task = Task(priority: .background) { await readHistory() }
        scan = task
        return task
    }

    private func readHistory() async {
        defer {
            isRefreshing = false
            scan = nil
        }
        do {
            while true {
                let result = try await fetch()
                try Task.checkCancellation()
                snapshot = result
                error = nil
                guard result.hasMoreFiles else { return }
                // Pace catch-up and let the UI present each batch before continuing.
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch is CancellationError {
            // Cancellation is not a source failure; keep the previous snapshot and error.
        } catch {
            // Never forward IO/decoder errors containing sensitive paths or payloads.
            // Failed enumeration must not replace the last reading with zero.
            self.error = HistoryReadError.unavailable.localizedDescription
        }
    }
}
