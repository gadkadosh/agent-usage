import XCTest

@testable import AgentUsage

@MainActor
final class DashboardPanelTests: XCTestCase {
    func testManualRefreshUpdatesBothSourcesAndPeriodSwitchDoesNotFetch() async {
        let readings = DashboardReadings()
        let (usage, history) = stores(readings)
        XCTAssertNil(history.snapshot)
        let before = await readings.counts
        XCTAssertEqual(before, [0, 0])
        await DashboardPanel(usage: usage, history: history).refresh()
        XCTAssertNotNil(usage.snapshot)
        XCTAssertEqual(history.summary?.tokens, 18_420)
        history.period = .week
        XCTAssertEqual(history.summary?.tokens, 331_560)
        history.period = .month
        XCTAssertEqual(history.summary?.tokens, 1_657_800)
        let after = await readings.counts
        XCTAssertEqual(after, [1, 1])
    }

    func testAllowanceFailureDoesNotBlockHistory() async {
        let readings = DashboardReadings(allowanceFails: true)
        let (usage, history) = stores(readings)
        await DashboardPanel(usage: usage, history: history).refresh()
        XCTAssertNotNil(usage.error)
        XCTAssertNil(usage.snapshot)
        XCTAssertNil(history.error)
        XCTAssertEqual(history.summary?.tokens, 18_420)
    }

    func testHistoryFailureDoesNotBlockAllowanceOrClearLastReading() async {
        let readings = DashboardReadings(failHistoryAfterFirst: true)
        let (usage, history) = stores(readings)
        let panel = DashboardPanel(usage: usage, history: history)
        await panel.refresh()
        let previous = history.snapshot
        await panel.refresh()
        XCTAssertNil(usage.error)
        XCTAssertNotNil(usage.snapshot)
        XCTAssertNotNil(history.error)
        XCTAssertEqual(history.snapshot?.fetchedAt, previous?.fetchedAt)
        XCTAssertEqual(history.summary?.tokens, 18_420)
    }

    func testUnreadableSourcesHaveAgentScopedStatusAndNoReadings() {
        for id in [HistoryAgentID.pi, .codex] {
            for (state, status) in [
                (HistoryCoverage.State.unavailable, "History could not be read."),
                (.unsupported, "Unsupported history format."),
            ] {
                let snapshot = DashboardFixtures.history(state: state, agents: [id])
                XCTAssertFalse(snapshot.coverage.hasReadings)
                XCTAssertEqual(snapshot.visibleSources.map(\.id), [id])
                XCTAssertEqual(snapshot.visibleSources.first?.status, status)
                XCTAssertEqual(snapshot.visibleSources.first?.coverage?.hasReadings, false)
            }
            XCTAssertTrue(
                DashboardFixtures.history(state: .missing, agents: [id]).visibleSources.isEmpty
            )
        }
        XCTAssertEqual(
            HistoryCoverage(state: .partial, hasReadings: true, issues: [.staleFile]).warning,
            "Partial history. Totals may be incomplete. Includes older readings."
        )
    }

    func testScreenshotFixtureIncludesAllAgents() {
        let snapshot = DashboardFixtures.history()
        XCTAssertEqual(snapshot.visibleSources.map(\.id), [.codex, .openCode, .pi])
        XCTAssertEqual(snapshot.summaries[.week]?.tokens, 331_560)
        XCTAssertEqual(
            snapshot.visibleSources.map { $0.summaries[.week]?.tokens },
            [55_260, 110_520, 165_780]
        )
    }

    private func stores(_ readings: DashboardReadings) -> (UsageStore, HistoryStore) {
        (
            UsageStore(fetch: { try await readings.allowance() }, now: { DashboardFixtures.now }),
            HistoryStore(fetch: { try await readings.history() })
        )
    }
}

/// Shared test-only fixtures; never construct live stores, discovery or networking.
enum DashboardFixtures {
    static let now = HistoryFixtures.now
    static let limits = UsageLimits(
        rateLimit: .init(
            primaryWindow: .init(usedPercent: 28, resetAfterSeconds: 8_280),
            secondaryWindow: .init(usedPercent: 54, resetAfterSeconds: 280_800)
        )
    )

    static func history(
        state: HistoryCoverage.State = .ready,
        zero: Bool = false,
        agents: [HistoryAgentID] = [.codex, .openCode, .pi]
    ) -> HistorySnapshot {
        let calendar = HistoryFixtures.calendar
        let coverage = HistoryCoverage(
            state: state,
            hasReadings: state == .ready || state == .partial,
            issues: state == .partial ? [.unsupportedVersion, .staleFile] : []
        )
        let weight = max(1, agents.count * (agents.count + 1) / 2)
        let observations = agents.enumerated().map { index, id -> [UsageObservation] in
            guard coverage.hasReadings && !zero else { return [] }
            return (0..<30).map { day in
                let tokens = (day % 5 + 1) * 18_420 * (index + 1) / weight
                return UsageObservation(
                    operationID: "\(id.rawValue)-synthetic-\(day)",
                    timestamp: calendar.date(byAdding: .day, value: -day, to: now)!,
                    tokens: Int64(tokens)
                )
            }
        }
        return HistorySnapshot(
            summaries: historySummaries(observations.flatMap { $0 }, now: now, calendar: calendar),
            coverage: coverage,
            fetchedAt: now,
            sources: agents.enumerated().map { index, id in
                HistorySourceSnapshot(
                    id: id,
                    summaries: historySummaries(observations[index], now: now, calendar: calendar),
                    coverage: coverage,
                    fetchedAt: now,
                    failed: false
                )
            }
        )
    }
}

actor DashboardReadings {
    private(set) var counts = [0, 0]
    let allowanceFails: Bool
    let failHistoryAfterFirst: Bool
    let snapshot: HistorySnapshot

    init(
        allowanceFails: Bool = false,
        failHistoryAfterFirst: Bool = false,
        snapshot: HistorySnapshot = DashboardFixtures.history()
    ) {
        self.allowanceFails = allowanceFails
        self.failHistoryAfterFirst = failHistoryAfterFirst
        self.snapshot = snapshot
    }

    func allowance() throws -> UsageLimits {
        counts[0] += 1
        if allowanceFails { throw URLError(.notConnectedToInternet) }
        return DashboardFixtures.limits
    }

    func history() throws -> HistorySnapshot {
        counts[1] += 1
        if failHistoryAfterFirst && counts[1] > 1 { throw HistoryReadError.unavailable }
        return snapshot
    }
}
