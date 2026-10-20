import Foundation

/// Retains accepted source data independently of adapter index caches and UI lifetime.
actor HistoryService {
    private let adapters: [any HistoryAdapter]
    private var accepted: [HistoryAgentID: HistoryAdapterResult] = [:]
    private var refreshTask: Task<HistorySnapshot, Error>?

    init(adapters: [any HistoryAdapter]) {
        precondition(Set(adapters.map(\.id)).count == adapters.count)
        self.adapters = adapters
    }

    func refresh(now: Date, calendar: Calendar) async throws -> HistorySnapshot {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh(now: now, calendar: calendar) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(now: Date, calendar: Calendar) async throws -> HistorySnapshot {
        let request = HistoryRequest(now: now, calendar: calendar)
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for adapter in adapters {
                group.addTask {
                    do {
                        return Outcome(id: adapter.id, result: try await adapter.read(request))
                    } catch {
                        return Outcome(id: adapter.id, result: nil)
                    }
                }
            }
            var outcomes: [Outcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        let failed = Set(outcomes.filter { $0.result == nil }.map(\.id))
        for outcome in outcomes {
            if let result = outcome.result { accepted[outcome.id] = result }
        }
        // Preserve the existing Pi-only initial failure presentation.
        guard !accepted.isEmpty else { throw HistoryReadError.unavailable }

        let sources = adapters.map { adapter in
            let result = accepted[adapter.id]
            return HistorySourceSnapshot(
                id: adapter.id,
                summaries: historySummaries(
                    result?.observations ?? [],
                    now: now,
                    calendar: calendar
                ),
                coverage: result?.coverage,
                fetchedAt: result?.fetchedAt,
                failed: failed.contains(adapter.id)
            )
        }
        // Aggregate each source separately so equal operation IDs from different agents survive.
        let summaries = Dictionary(
            uniqueKeysWithValues: HistoryPeriod.allCases.map { period in
                var combined = PeriodSummary.aggregate(
                    [],
                    period: period,
                    now: now,
                    calendar: calendar
                )
                for source in sources {
                    guard let summary = source.summaries[period] else { continue }
                    combined = PeriodSummary(
                        tokens: combined.tokens + summary.tokens,
                        buckets: zip(combined.buckets, summary.buckets).map { left, right in
                            var bucket = left
                            bucket.tokens += right.tokens
                            return bucket
                        }
                    )
                }
                return (period, combined)
            }
        )
        let results = adapters.compactMap { accepted[$0.id] }
        // Pi-only composition preserves its existing detailed coverage and footer timestamp.
        let coverage =
            results.count == 1
            ? results[0].coverage
            : HistoryCoverage(
                state: failed.isEmpty && results.allSatisfy { $0.coverage.state == .ready }
                    ? .ready : .partial,
                issues: results.reduce(into: Set<HistoryIssue>()) {
                    $0.formUnion($1.coverage.issues)
                },
                observedReadings: results.contains { $0.coverage.hasReadings }
            )
        return HistorySnapshot(
            summaries: summaries,
            coverage: coverage,
            fetchedAt: results.map(\.fetchedAt).min() ?? now,
            hasMoreFiles: outcomes.contains { $0.result?.hasMore == true },
            sources: sources,
            refreshError: failed.isEmpty ? nil : HistoryReadError.unavailable.localizedDescription
        )
    }

    private struct Outcome: Sendable {
        let id: HistoryAgentID
        let result: HistoryAdapterResult?
    }
}
