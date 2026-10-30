import Foundation

/// Owns accepted contributions, refresh scheduling and aggregation, independently of UI lifetime.
actor HistoryService {
    private let adapters: [any HistoryAdapter]
    private var readings: [HistoryAgentID: SourceReading] = [:]
    private var refreshTask: Task<HistorySnapshot, Error>?

    init(adapters: [any HistoryAdapter]) {
        precondition(Set(adapters.map(\.id)).count == adapters.count)
        self.adapters = adapters
    }

    /// Overlapping callers join the complete refresh. The initiating caller receives updates;
    /// joiners receive its final snapshot without starting another read or replacing its observer.
    func refresh(
        now: Date,
        calendar: Calendar,
        onUpdate: @escaping @Sendable (HistorySnapshot) async -> Void = { _ in }
    ) async throws -> HistorySnapshot {
        if let refreshTask { return try await refreshTask.value }
        let request = HistoryRequest(now: now, calendar: calendar)
        let task = Task { try await performRefresh(request, onUpdate: onUpdate) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(
        _ request: HistoryRequest,
        onUpdate: @escaping @Sendable (HistorySnapshot) async -> Void
    ) async throws -> HistorySnapshot {
        var loading = Set(adapters.map(\.id))
        var latest: HistorySnapshot?
        await withTaskGroup(of: Outcome.self) { group in
            for adapter in adapters {
                group.addTask { await Self.read(adapter, request: request) }
            }
            for await outcome in group {
                let adapter = outcome.adapter
                readings[adapter.id, default: SourceReading()].accept(outcome.result)
                if outcome.result?.hasMore == true {
                    // Pace only this source's catch-up; other sources keep progressing.
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(100))
                        return await Self.read(adapter, request: request)
                    }
                } else {
                    loading.remove(adapter.id)
                }
                // Once progress is published, keep its status current through completion,
                // even when later failures leave no source results available.
                if latest != nil || hasSourceResult {
                    let result = snapshot(request, loading: loading)
                    latest = result
                    await onUpdate(result)
                }
            }
        }
        // Reuse the last publication, including all retained sources, without aggregating again.
        guard let latest else { throw HistoryReadError.unavailable }
        return latest
    }

    private static func read(_ adapter: any HistoryAdapter, request: HistoryRequest) async
        -> Outcome
    {
        Outcome(adapter: adapter, result: try? await adapter.read(request))
    }

    private var hasSourceResult: Bool {
        readings.values.contains { $0.accepted != nil || $0.latest != nil }
    }

    private func snapshot(_ request: HistoryRequest, loading: Set<HistoryAgentID>)
        -> HistorySnapshot
    {
        let sources = adapters.map { adapter in
            let reading = readings[adapter.id, default: SourceReading()]
            return HistorySourceSnapshot(
                id: adapter.id,
                summaries: historySummaries(
                    reading.accepted?.observations ?? [],
                    now: request.now,
                    calendar: request.calendar
                ),
                coverage: reading.coverage,
                fetchedAt: reading.accepted?.fetchedAt,
                failed: reading.failed,
                isLoading: loading.contains(adapter.id)
            )
        }
        // Aggregate separately so equal operation IDs from different agents survive.
        let summaries = Dictionary(
            uniqueKeysWithValues: HistoryPeriod.allCases.map { period in
                var buckets = PeriodSummary.aggregate(
                    [],
                    period: period,
                    now: request.now,
                    calendar: request.calendar
                ).buckets
                var cost = RecordedCostSummary()
                for source in sources {
                    guard let summary = source.summaries[period] else { continue }
                    cost.merge(summary.cost)
                    for index in buckets.indices {
                        buckets[index].tokens += summary.buckets[index].tokens
                    }
                }
                return (
                    period,
                    PeriodSummary(
                        tokens: buckets.reduce(0) { $0 + $1.tokens },
                        buckets: buckets,
                        cost: cost
                    )
                )
            }
        )
        return HistorySnapshot(
            summaries: summaries,
            coverage: .combined(sources.compactMap(\.coverage)),
            fetchedAt: sources.compactMap(\.fetchedAt).min() ?? request.now,
            hasMore: !loading.isEmpty,
            sources: sources
        )
    }

    /// Keep the latest attempt's status separate from its last usable measurement.
    private struct SourceReading {
        var accepted: HistoryAdapterResult?
        var latest: HistoryCoverage?
        var failed = false

        mutating func accept(_ result: HistoryAdapterResult?) {
            latest = result?.coverage
            guard let result else {
                failed = true
                return
            }
            guard result.coverage.replacesReadings else {
                failed = accepted?.coverage.hasReadings == true
                return
            }
            accepted = result
            failed = false
        }

        var coverage: HistoryCoverage? {
            guard latest != nil || failed else { return nil }
            var issues = latest?.issues ?? []
            if failed, accepted?.coverage.hasReadings == true {
                issues.formUnion(accepted?.coverage.issues ?? [])
            }
            return HistoryCoverage(
                state: latest?.state ?? .unavailable,
                hasReadings: accepted?.coverage.hasReadings == true,
                issues: issues
            )
        }
    }

    private struct Outcome: Sendable {
        let adapter: any HistoryAdapter
        let result: HistoryAdapterResult?
    }
}
