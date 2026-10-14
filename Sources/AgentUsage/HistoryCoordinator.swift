import Foundation

/// Refreshes adapters independently. Failed sources retain only their last normalized readings.
actor HistoryCoordinator {
    private struct Reading: Sendable {
        let value: HistoryReadings
        let fetchedAt: Date
    }

    private let sources: [HistorySource]
    private var readings: [HistoryAgent: Reading] = [:]
    private var failed: Set<HistoryAgent> = []
    private var pending: Set<HistoryAgent> = []
    private var context: HistoryReadContext?

    init(sources: [HistorySource]) {
        precondition(Set(sources.map(\.agent)).count == sources.count)
        self.sources = sources
    }

    /// The store serializes calls. Catch-up batches reuse one clock and only retry advancing sources.
    func refresh(now: Date, calendar: Calendar) async -> HistorySnapshot {
        if pending.isEmpty {
            context = HistoryReadContext(now: now, calendar: calendar)
            pending = Set(sources.map(\.agent))
            failed = []
        }
        let context = context!
        let batch = sources.filter { pending.contains($0.agent) }
        pending = []
        await withTaskGroup(of: (HistoryAgent, HistoryReadings?).self) { group in
            for source in batch {
                group.addTask { (source.agent, try? await source.read(context)) }
            }
            for await (agent, result) in group {
                if let result {
                    readings[agent] = Reading(value: result, fetchedAt: context.now)
                    if result.hasMoreFiles { pending.insert(agent) }
                } else {
                    // Do not retain or publish storage errors, which can contain private data.
                    failed.insert(agent)
                }
            }
        }
        let agents = sources.map { source in
            let reading = readings[source.agent]
            let snapshot = reading?.value.snapshot(in: context)
            return AgentHistorySummary(
                agent: source.agent,
                summaries: snapshot?.summaries ?? [:],
                coverage: snapshot?.coverage
                    ?? HistoryCoverage(state: .unavailable, filesRead: 0, issues: []),
                fetchedAt: reading?.fetchedAt,
                refreshFailed: failed.contains(source.agent),
                isLoading: pending.contains(source.agent)
            )
        }
        // Aggregate each source separately: identical operation IDs across agents never collide.
        let summaries = Dictionary(
            uniqueKeysWithValues: HistoryPeriod.allCases.map { period in
                var combined = PeriodSummary.aggregate(
                    [],
                    period: period,
                    now: context.now,
                    calendar: context.calendar
                ).buckets
                for agent in agents {
                    guard let summary = agent.summaries[period] else { continue }
                    for index in combined.indices {
                        combined[index].tokens += summary.buckets[index].tokens
                    }
                }
                return (
                    period,
                    PeriodSummary(tokens: combined.reduce(0) { $0 + $1.tokens }, buckets: combined)
                )
            }
        )
        let hasReadings = agents.contains { $0.coverage.hasReadings }
        let incomplete = agents.contains {
            $0.refreshFailed || [.partial, .unavailable, .unsupported].contains($0.coverage.state)
        }
        let state: HistoryCoverage.State =
            hasReadings
            ? (incomplete ? .partial : .ready)
            : agents.contains(where: { $0.refreshFailed || $0.coverage.state == .unavailable })
                ? .unavailable
                : agents.contains(where: { $0.coverage.state == .unsupported })
                    ? .unsupported : .missing
        return HistorySnapshot(
            summaries: summaries,
            coverage: HistoryCoverage(
                state: state,
                filesRead: agents.reduce(0) { $0 + $1.coverage.filesRead },
                issues: agents.reduce(into: []) { $0.formUnion($1.coverage.issues) },
                filesSkipped: agents.reduce(0) { $0 + $1.coverage.filesSkipped }
            ),
            fetchedAt: context.now,
            hasMoreFiles: !pending.isEmpty,
            agents: agents
        )
    }
}
