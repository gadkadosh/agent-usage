import Foundation

/// Owns accepted contributions, refresh scheduling and aggregation, independently of UI lifetime.
actor HistoryService {
    private let adapters: [any HistoryAdapter]
    private var readings: [HistoryAgentID: SourceReading] = [:]
    private var refreshTask: Task<HistorySnapshot, Error>?
    private var request: HistoryRequest?
    private var pending: Set<HistoryAgentID> = []

    init(adapters: [any HistoryAdapter]) {
        precondition(Set(adapters.map(\.id)).count == adapters.count)
        self.adapters = adapters
    }

    /// Overlapping callers join the current batch. The initiating caller receives updates;
    /// joiners receive its final snapshot without starting another read or replacing its observer.
    func refresh(
        now: Date,
        calendar: Calendar,
        onUpdate: @escaping @Sendable (HistorySnapshot) async -> Void = { _ in }
    ) async throws -> HistorySnapshot {
        if let refreshTask { return try await refreshTask.value }
        let request: HistoryRequest
        if let previous = self.request, !pending.isEmpty {
            request = previous
        } else {
            request = HistoryRequest(now: now, calendar: calendar)
            pending = Set(adapters.map(\.id))
        }
        self.request = request
        let task = Task { try await performBatch(request, onUpdate: onUpdate) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performBatch(
        _ request: HistoryRequest,
        onUpdate: @escaping @Sendable (HistorySnapshot) async -> Void
    ) async throws -> HistorySnapshot {
        let batch = adapters.filter { pending.contains($0.id) }
        pending.removeAll()
        await withTaskGroup(of: Outcome.self) { group in
            for adapter in batch {
                group.addTask {
                    Outcome(id: adapter.id, result: try? await adapter.read(request))
                }
            }
            var running = Set(batch.map(\.id))
            for await outcome in group {
                running.remove(outcome.id)
                if readings[outcome.id, default: SourceReading()].accept(outcome.result) {
                    pending.insert(outcome.id)
                }
                // Publish each completed source even while other adapters are still reading.
                // An initial all-source IO failure keeps the existing unavailable presentation.
                if canPublish {
                    await onUpdate(snapshot(request, loading: running.union(pending)))
                }
            }
        }
        guard canPublish else { throw HistoryReadError.unavailable }
        return snapshot(request, loading: pending)
    }

    private var canPublish: Bool {
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
                for source in sources {
                    guard let summary = source.summaries[period] else { continue }
                    for index in buckets.indices {
                        buckets[index].tokens += summary.buckets[index].tokens
                    }
                }
                return (
                    period,
                    PeriodSummary(tokens: buckets.reduce(0) { $0 + $1.tokens }, buckets: buckets)
                )
            }
        )
        return HistorySnapshot(
            summaries: summaries,
            coverage: .combined(sources.compactMap(\.coverage)),
            fetchedAt: sources.compactMap(\.fetchedAt).min() ?? request.now,
            hasMore: !loading.isEmpty,
            sources: sources,
            refreshError: sources.contains { $0.failed }
                ? HistoryReadError.unavailable.localizedDescription : nil
        )
    }

    /// Keep the latest attempt's status separate from its last usable measurement.
    private struct SourceReading {
        var accepted: HistoryAdapterResult?
        var latest: HistoryCoverage?
        var failed = false

        /// Returns true only when an accepted result requests another batch.
        mutating func accept(_ result: HistoryAdapterResult?) -> Bool {
            latest = result?.coverage
            guard let result else {
                failed = true
                return false
            }
            guard result.coverage.replacesReadings else {
                failed = accepted?.coverage.hasReadings == true
                return false
            }
            accepted = result
            failed = false
            return result.hasMore
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
        let id: HistoryAgentID
        let result: HistoryAdapterResult?
    }
}
