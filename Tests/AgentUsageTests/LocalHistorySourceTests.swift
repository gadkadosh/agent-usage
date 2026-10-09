import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class LocalHistorySourceTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testLiveCombinedTotalsAndEveryBucketEqualTheTwoSubtotalsForEachPeriod() async throws {
        let pi = try PiHistoryFixtureRoot()
        let oc = try OpenCodeHistoryFixture()
        defer {
            pi.remove()
            oc.remove()
        }
        var lines = [F.header()]
        for (seq, days) in [0, 3, 20].enumerated() {
            let date = F.calendar.date(byAdding: .day, value: -days, to: F.now)!
            // The same ID at both agents must never deduplicate across agent boundaries.
            lines.append(
                F.message(id: "msg_day\(days)", time: Int64(date.timeIntervalSince1970 * 1_000))
            )
            try oc.message(id: "msg_day\(days)", seq: seq, at: date)
        }
        try pi.write(lines: lines)
        let store = HistoryStore.live(
            root: pi.root,
            openCodeDatabase: oc.database,
            now: { F.now },
            calendar: F.calendar
        )
        await store.refresh()
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(snapshot.agents.map(\.agent), [.pi, .opencode])
        XCTAssertEqual(snapshot.coverage.state, .ready)
        for (period, expected) in [(HistoryPeriod.today, Int64(390)), (.week, 780), (.month, 1170)]
        {
            store.period = period
            let total = try XCTUnwrap(store.summary)
            XCTAssertEqual(total.tokens, expected)
            let piSummary = try XCTUnwrap(snapshot.agents[0].summaries[period])
            let ocSummary = try XCTUnwrap(snapshot.agents[1].summaries[period])
            XCTAssertEqual(total.tokens, piSummary.tokens + ocSummary.tokens)
            for index in total.buckets.indices {
                XCTAssertEqual(
                    total.buckets[index].tokens,
                    piSummary.buckets[index].tokens + ocSummary.buckets[index].tokens
                )
            }
        }
    }

    func testFailedOpenCodeReadRetainsItsSubtotalWhilePiUpdatesThenRecovers() async throws {
        let pi = try PiHistoryFixtureRoot()
        let oc = try OpenCodeHistoryFixture()
        defer {
            pi.remove()
            oc.remove()
        }
        try pi.write(lines: [F.header(), F.message()])
        try oc.message()
        let store = HistoryStore.live(
            root: pi.root,
            openCodeDatabase: oc.database,
            now: { F.now },
            calendar: F.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 390)
        let before = try Data(contentsOf: oc.database)
        try Data("invented corruption".utf8).write(to: oc.database)
        try pi.write(lines: [F.header(), F.message(), F.message(id: "new")])
        await store.refresh()
        let failed = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(store.summary?.tokens, 580)
        XCTAssertEqual(failed.agents[0].summaries[.today]?.tokens, 380)
        XCTAssertEqual(failed.agents[1].summaries[.today]?.tokens, 200)
        XCTAssertFalse(failed.agents[0].refreshFailed)
        XCTAssertTrue(failed.agents[1].refreshFailed)
        XCTAssertEqual(failed.coverage.state, .partial)
        XCTAssertTrue(failed.coverage.issues.contains(.staleFile))
        XCTAssertNil(store.error)
        try before.write(to: oc.database)
        try oc.message(id: "msg_recovered", seq: 2)
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 780)
        XCTAssertEqual(store.snapshot?.coverage.state, .ready)
        XCTAssertTrue(store.snapshot?.agents.allSatisfy { !$0.refreshFailed } == true)
    }

    func testMissingPiStillShowsOpenCodeAndUnsupportedOpenCodeDoesNotBecomeZero() async throws {
        let pi = try PiHistoryFixtureRoot()
        let oc = try OpenCodeHistoryFixture()
        defer {
            pi.remove()
            oc.remove()
        }
        try oc.message()
        let missingPi = pi.root.appendingPathComponent("missing")
        let store = HistoryStore.live(
            root: missingPi,
            openCodeDatabase: oc.database,
            now: { F.now },
            calendar: F.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)
        XCTAssertEqual(store.snapshot?.coverage.state, .ready)
        XCTAssertEqual(store.snapshot?.agents[0].coverage.state, .missing)
        XCTAssertFalse(store.snapshot?.agents[0].coverage.hasReadings == true)

        try pi.write(lines: [F.header(), F.message()])
        try oc.execute("DROP TABLE session_message")
        let unsupported = HistoryStore.live(
            root: pi.root,
            openCodeDatabase: oc.database,
            now: { F.now },
            calendar: F.calendar
        )
        await unsupported.refresh()
        XCTAssertEqual(unsupported.summary?.tokens, 190)
        XCTAssertEqual(unsupported.snapshot?.agents[1].coverage.state, .unsupported)
        XCTAssertFalse(unsupported.snapshot?.agents[1].coverage.hasReadings == true)
        XCTAssertEqual(unsupported.snapshot?.coverage.state, .partial)
    }

    func testSchemaBecomingUnsupportedKeepsLastReadingButActualDeletionRemovesIt() async throws {
        let pi = try PiHistoryFixtureRoot()
        let oc = try OpenCodeHistoryFixture()
        defer {
            pi.remove()
            oc.remove()
        }
        try pi.write(lines: [F.header(), F.message()])
        try oc.message()
        let store = HistoryStore.live(
            root: pi.root,
            openCodeDatabase: oc.database,
            now: { F.now },
            calendar: F.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 390)
        try oc.execute("DROP TABLE session_message")
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 390)
        XCTAssertTrue(store.snapshot?.agents[1].refreshFailed == true)
        XCTAssertEqual(store.snapshot?.coverage.state, .partial)
        try FileManager.default.removeItem(at: oc.database)
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 190)
        XCTAssertEqual(store.snapshot?.agents[1].coverage.state, .missing)
        XCTAssertFalse(store.snapshot?.agents[1].refreshFailed == true)
    }

    func testBothInitialFailuresRemainUnavailableAndDoNotExposeErrorsOrRetry() async throws {
        let source = LocalHistorySource(fetchers: [
            .pi: { _, _ in throw URLError(.noPermissionsToReadFile) },
            .opencode: { _, _ in throw URLError(.cannotDecodeContentData) },
        ])
        let snapshot = await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertFalse(snapshot.coverage.hasReadings)
        XCTAssertEqual(snapshot.coverage.state, .unavailable)
        XCTAssertTrue(snapshot.agents.allSatisfy { $0.refreshFailed && !$0.coverage.hasReadings })
        XCTAssertFalse(snapshot.hasMoreFiles)
    }

    func testFailedTodayReadingDoesNotLeakYesterdayIntoTodayAndPeriodSwitchDoesNotFetch()
        async throws
    {
        let readings = ScriptedHistoryReadings()
        let source = LocalHistorySource(fetchers: [
            .pi: { now, calendar in await readings.pi(now: now, calendar: calendar) },
            .opencode: { now, calendar in try await readings.opencode(now: now, calendar: calendar)
            },
        ])
        let first = await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(first.summaries[.today]?.tokens, 390)
        await readings.failOpenCode()
        let tomorrow = F.calendar.date(byAdding: .day, value: 1, to: F.now)!
        let second = await source.refresh(now: tomorrow, calendar: F.calendar)
        XCTAssertEqual(second.summaries[.today]?.tokens, 190)
        XCTAssertEqual(second.agents[1].summaries[.today]?.tokens, 0)
        XCTAssertEqual(second.summaries[.week]?.tokens, 390)
        XCTAssertTrue(second.agents[1].refreshFailed)
        let store = HistoryStore(fetch: { second })
        await store.refresh()
        for period in HistoryPeriod.allCases { store.period = period }
        let counts = await readings.counts
        XCTAssertEqual(counts, [2, 2])
    }

    func testPiCatchUpDoesNotDisappearWhenOtherSourceFails() async throws {
        let pi = try PiHistoryFixtureRoot()
        defer { pi.remove() }
        let lines = [F.header(), F.message()]
        let first = try pi.write("a.jsonl", lines: lines)
        try pi.write("b.jsonl", lines: [F.header(), F.message(id: "second")])
        let size = try Data(contentsOf: first).count
        let piSource = PiHistorySource(root: pi.root, limits: .init(refreshBytes: size))
        let source = LocalHistorySource(fetchers: [
            .pi: { try await piSource.refresh(now: $0, calendar: $1) },
            .opencode: { _, _ in throw HistoryReadError.unavailable },
        ])
        let store = HistoryStore(fetch: { await source.refresh(now: F.now, calendar: F.calendar) })
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 380)
        XCTAssertFalse(store.snapshot?.hasMoreFiles == true)
        XCTAssertEqual(store.snapshot?.coverage.state, .partial)
        XCTAssertFalse(store.isRefreshing)
    }
}

private actor ScriptedHistoryReadings {
    private var fails = false
    private(set) var counts = [0, 0]
    func failOpenCode() { fails = true }

    func pi(now: Date, calendar: Calendar) -> HistorySnapshot {
        counts[0] += 1
        return snapshot(tokens: 190, now: now, calendar: calendar)
    }

    func opencode(now: Date, calendar: Calendar) throws -> HistorySnapshot {
        counts[1] += 1
        if fails { throw HistoryReadError.unavailable }
        return snapshot(tokens: 200, now: now, calendar: calendar)
    }

    private func snapshot(tokens: Int64, now: Date, calendar: Calendar) -> HistorySnapshot {
        let observation = UsageObservation(operationID: "same-id", timestamp: now, tokens: tokens)
        return HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            [observation],
                            period: $0,
                            now: now,
                            calendar: calendar
                        )
                    )
                }
            ),
            coverage: HistoryCoverage(state: .ready, filesRead: 1, issues: []),
            fetchedAt: now
        )
    }
}
