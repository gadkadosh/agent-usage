import Foundation

/// Combines independent sources. One failed read never discards the other agent's new usage.
actor LocalHistorySource {
    typealias Fetch = @Sendable (Date, Calendar) async throws -> HistorySnapshot
    private let fetchers: [HistoryAgent: Fetch]
    private var lastReadings: [HistoryAgent: HistorySnapshot] = [:]

    init(fetchers: [HistoryAgent: Fetch]) {
        self.fetchers = fetchers
    }

    func refresh(now: Date, calendar: Calendar) async -> HistorySnapshot {
        // Freeze autoupdating calendars so all asynchronous readers share one set of boundaries.
        var fixedCalendar = calendar
        fixedCalendar.timeZone = calendar.timeZone
        let calendar = fixedCalendar
        let readings = await withTaskGroup(of: (HistoryAgent, HistorySnapshot?).self) { group in
            for (agent, fetch) in fetchers {
                group.addTask { (agent, try? await fetch(now, calendar)) }
            }
            var readings: [HistoryAgent: HistorySnapshot] = [:]
            for await (agent, snapshot) in group {
                if let snapshot { readings[agent] = snapshot }
            }
            return readings
        }
        var agents: [AgentHistory] = []
        for agent in HistoryAgent.allCases where fetchers[agent] != nil {
            let reading = readings[agent]
            let unusable =
                reading.map { !$0.coverage.hasReadings && $0.coverage.state != .missing } ?? true
            let failed =
                reading == nil || (unusable && lastReadings[agent]?.coverage.hasReadings == true)
            if let reading, !failed { lastReadings[agent] = reading }
            let snapshot =
                lastReadings[agent] ?? reading
                ?? HistorySnapshot(
                    summaries: [:],
                    coverage: HistoryCoverage(
                        state: .unavailable,
                        filesRead: 0,
                        issues: [.unreadableFile]
                    ),
                    fetchedAt: now
                )
            // Fresh readings already use this calendar. Rebuild stale readings from request
            // timestamps: daily totals cannot be re-sliced exactly after time-zone changes.
            let aligned =
                failed
                ? HistorySnapshot(
                    summaries: Dictionary(
                        uniqueKeysWithValues: HistoryPeriod.allCases.map {
                            (
                                $0,
                                PeriodSummary.aggregate(
                                    snapshot.observations,
                                    period: $0,
                                    now: now,
                                    calendar: calendar
                                )
                            )
                        }
                    ),
                    coverage: snapshot.coverage,
                    fetchedAt: snapshot.fetchedAt
                ) : snapshot
            agents.append(AgentHistory(agent: agent, snapshot: aligned, refreshFailed: failed))
        }
        let hasReadings = agents.contains { $0.coverage.hasReadings }
        let incomplete = agents.contains {
            $0.refreshFailed || [.partial, .unsupported, .unavailable].contains($0.coverage.state)
        }
        let state: HistoryCoverage.State =
            hasReadings
            ? (incomplete ? .partial : .ready)
            : agents.allSatisfy({ $0.coverage.state == .missing })
                ? .missing
                : agents.contains(where: { $0.coverage.state == .unavailable || $0.refreshFailed })
                    ? .unavailable : .unsupported
        var issues = agents.reduce(into: Set<HistoryIssue>()) { $0.formUnion($1.coverage.issues) }
        if agents.contains(where: { $0.refreshFailed && $0.coverage.hasReadings }) {
            issues.insert(.staleFile)
        }
        return HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map { period in
                    (
                        period,
                        PeriodSummary.combine(
                            agents.compactMap { $0.summaries[period] },
                            period: period,
                            now: now,
                            calendar: calendar
                        )
                    )
                }
            ),
            coverage: HistoryCoverage(
                state: state,
                filesRead: agents.reduce(0) { $0 + $1.coverage.filesRead },
                issues: issues,
                filesSkipped: agents.reduce(0) { $0 + $1.coverage.filesSkipped }
            ),
            fetchedAt: now,
            // Retry only successful sources' explicit byte-budget deferrals, never read failures.
            hasMoreFiles: readings.values.contains { $0.hasMoreFiles },
            agents: agents
        )
    }
}

extension PeriodSummary {
    /// Source operation IDs never cross agent boundaries. Add totals on shared calendar buckets.
    static func combine(_ summaries: [Self], period: HistoryPeriod, now: Date, calendar: Calendar)
        -> Self
    {
        let template = aggregate([], period: period, now: now, calendar: calendar)
        var totals: [Date: Int64] = [:]
        for summary in summaries {
            for bucket in summary.buckets { totals[bucket.start, default: 0] += bucket.tokens }
        }
        let buckets = template.buckets.map {
            HistoryBucket(start: $0.start, end: $0.end, tokens: totals[$0.start] ?? 0)
        }
        return Self(tokens: buckets.reduce(0) { $0 + $1.tokens }, buckets: buckets)
    }
}
