import Foundation
import SwiftUI

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published var period: HistoryPeriod = .today
    @Published var showsSourceDetails = false

    var summary: PeriodSummary? { snapshot?.summaries[period] }

    private let fetch: @Sendable () async throws -> HistorySnapshot
    private var polling: Task<Void, Never>?

    init(fetch: @escaping @Sendable () async throws -> HistorySnapshot) {
        self.fetch = fetch
    }

    static func live() -> HistoryStore {
        let source = PiHistorySource(root: PiHistorySource.defaultRoot())
        return HistoryStore(fetch: { try await source.refresh() })
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    deinit { polling?.cancel() }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            snapshot = result
            error = nil
        } catch is CancellationError {
            // Cancellation is not a source failure; keep the last successful snapshot.
        } catch {
            // Do not forward IO/decoder errors, which may contain sensitive paths or payloads.
            self.error = HistoryReadError.unavailable.localizedDescription
        }
    }
}
