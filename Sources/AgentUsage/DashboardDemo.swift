import Foundation

/// Explicit demo mode never constructs a live credential/history source or contacts a provider.
struct DashboardDemo {
    let scenario: String
    let now = Date(timeIntervalSince1970: 1_790_942_400)  // 2026-10-02 12:00 UTC

    var isStale: Bool { scenario == "stale" }

    @MainActor
    func makeUsageStore() -> UsageStore {
        let readings = DemoReadings(stale: isStale)
        let now = now
        return UsageStore(fetch: { try await readings.allowance() }, now: { now })
    }

    @MainActor
    func makeHistoryStore() -> HistoryStore {
        let readings = DemoReadings(stale: isStale)
        let value = historySnapshot()
        return HistoryStore(fetch: {
            try await readings.history()
            return value
        })
    }

    func historySnapshot() -> HistorySnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let observations = (0..<30).map { day in
            UsageObservation(
                operationID: "demo-\(day)",
                timestamp: calendar.date(
                    byAdding: .day, value: -day, to: now.addingTimeInterval(-3_600))!,
                tokens: Int64((day % 5 + 1) * 18_420)
            )
        }
        let missing = scenario == "missing"
        return HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            missing ? [] : observations, period: $0, now: now, calendar: calendar)
                    )
                }),
            coverage: HistoryCoverage(
                state: missing ? .missing : (scenario == "partial" ? .partial : .ready),
                filesRead: missing ? 0 : 12,
                issues: scenario == "partial" ? [.unsupportedVersion, .incompleteLine] : []
            ), fetchedAt: now
        )
    }
}

private struct DemoAllowanceError: LocalizedError {
    var errorDescription: String? { "Synthetic allowance refresh failed." }
}

private actor DemoReadings {
    let stale: Bool
    private var allowanceReads = 0
    private var historyReads = 0

    init(stale: Bool) { self.stale = stale }

    func allowance() throws -> UsageLimits {
        allowanceReads += 1
        if stale && allowanceReads > 1 { throw DemoAllowanceError() }
        return UsageLimits(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 28, resetAfterSeconds: 8_280),
                secondaryWindow: .init(usedPercent: 54, resetAfterSeconds: 280_800)
            ))
    }

    func history() throws {
        historyReads += 1
        if stale && historyReads > 1 { throw HistoryReadError.unavailable }
    }
}
