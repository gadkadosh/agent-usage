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

    func testCoverageMessagesDoNotPresentUnreadableSourcesAsZero() {
        for state in [HistoryCoverage.State.missing, .partial, .unavailable, .unsupported] {
            let coverage = HistoryCoverage(state: state, filesRead: 0, issues: [])
            XCTAssertFalse(coverage.hasReadings)
            XCTAssertFalse(coverage.emptyDescription.contains("No recorded"))
        }
        XCTAssertEqual(
            HistoryCoverage(state: .partial, filesRead: 1, issues: [.staleFile]).detailsTitle,
            "Partial history · details")
        XCTAssertTrue(
            HistoryCoverage(state: .missing, filesRead: 0, issues: []).emptyDescription
                .contains("isn't zero usage"))
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
    static let now = PiHistoryFixtures.now
    static let limits = UsageLimits(
        rateLimit: .init(
            primaryWindow: .init(usedPercent: 28, resetAfterSeconds: 8_280),
            secondaryWindow: .init(usedPercent: 54, resetAfterSeconds: 280_800)))

    static func history(
        state: HistoryCoverage.State = .ready, zero: Bool = false
    ) -> HistorySnapshot {
        let readable = state == .ready || state == .partial
        let calendar = Calendar.autoupdatingCurrent
        let observations = (0..<30).map { day in
            UsageObservation(
                operationID: "synthetic-\(day)",
                timestamp: calendar.date(byAdding: .day, value: -day, to: now)!,
                tokens: Int64((day % 5 + 1) * 18_420))
        }
        return HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            readable && !zero ? observations : [], period: $0, now: now,
                            calendar: calendar)
                    )
                }),
            coverage: HistoryCoverage(
                state: state, filesRead: readable ? 12 : 0,
                issues: state == .partial ? [.unsupportedVersion, .staleFile] : []),
            fetchedAt: now)
    }
}

actor DashboardReadings {
    private(set) var counts = [0, 0]
    let allowanceFails: Bool
    let failHistoryAfterFirst: Bool
    let snapshot: HistorySnapshot

    init(
        allowanceFails: Bool = false, failHistoryAfterFirst: Bool = false,
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
