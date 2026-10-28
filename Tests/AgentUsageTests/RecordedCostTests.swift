import Foundation
import XCTest

@testable import AgentUsage

final class RecordedCostTests: XCTestCase {
    private typealias F = PiHistoryFixtures
    private let request = HistoryRequest(
        now: HistoryFixtures.now,
        calendar: HistoryFixtures.calendar
    )

    func testPiReadsCanonicalCostsWithoutAddingBreakdownsOrNestedToolCosts() {
        let parser = F.parser([
            F.header(),
            F.message(
                usage: piUsage(#"{"total":0.012345,"input":99,"output":99}"#),
                extra: #", "details":{"usage":{"cost":{"total":999}}}"#
            ),
            F.entry("usage", id: "usage", usage: piUsage(#"{"total":0}"#)),
            F.entry("compaction", id: "compact", usage: piUsage(#"{"total":1.25}"#)),
            F.entry("branch_summary", id: "branch", usage: piUsage(#"{"total":2}"#)),
        ])
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 120, 120, 120])
        XCTAssertEqual(
            parser.observations.map(\.costUSD),
            [decimal("0.012345"), 0, decimal("1.25"), 2]
        )
    }

    func testMissingAndInvalidPiCostsNeverDiscardTokens() {
        for cost in [
            nil, "null", "[]", "true", "123", #"{"total":null}"#,
            #"{"total":-1}"#, #"{"total":1e100}"#, #"{"total":"1.25"}"#,
            #"{"total":{}}"#, #"{"input":1}"#,
        ] as [String?] {
            let parser = F.parser([F.header(), F.message(usage: piUsage(cost))])
            XCTAssertTrue(parser.issues.isEmpty, "\(cost ?? "absent")")
            XCTAssertEqual(parser.observations.map(\.tokens), [120])
            XCTAssertNil(parser.observations.first?.costUSD, "\(cost ?? "absent")")
        }
    }

    func testPiCopiesDeduplicateCostAndConflictingCostsDoNotEraseTokens() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let source = PiHistorySource(root: fixture.root)
        for (name, cost) in [("a", "1.25"), ("b", "1.25")] {
            try fixture.write(
                "\(name).jsonl",
                lines: [F.header(), F.message(usage: piUsage("{\"total\":\(cost)}"))]
            )
        }
        let first = try await source.read(request)
        XCTAssertEqual(first.observations.count, 1)
        XCTAssertEqual(first.observations.first?.costUSD, decimal("1.25"))
        // A cost-only correction is reparsed even though tokens and identity haven't changed.
        try fixture.write(
            "b.jsonl",
            lines: [F.header(), F.message(usage: piUsage(#"{"total":2}"#))]
        )
        try fixture.write(
            "c.jsonl",
            lines: [F.header(), F.message(usage: piUsage(#"{"total":1.25}"#))]
        )
        let conflict = try await source.read(request)
        XCTAssertEqual(conflict.observations.map(\.tokens), [120])
        XCTAssertNil(conflict.observations.first?.costUSD)
        XCTAssertTrue(conflict.coverage.issues.isEmpty)
        XCTAssertEqual(summary(conflict).cost.display, "Unavailable")
    }

    func testMissingCopyDoesNotOverrideKnownCost() {
        let known = UsageObservation(
            operationID: "copy",
            timestamp: request.now,
            tokens: 10,
            costUSD: 2
        )
        let missing = UsageObservation(operationID: "copy", timestamp: request.now, tokens: 10)
        for copies in [[known, missing], [missing, known]] {
            var issues: Set<HistoryIssue> = []
            let observations = canonicalHistoryObservations(copies, format: .pi, issues: &issues)
            XCTAssertEqual(observations, [known])
            XCTAssertTrue(issues.isEmpty)
        }
    }

    func testOpenCodeReadsEventsAndProjectionFallbackWithoutDoubleCounting() async throws {
        let fixture = try OpenCodeHistoryFixture()
        try fixture.message("msg_response", cost: "99")
        try fixture.event(
            "response",
            type: "session.step.ended.1",
            cost: "0.012345",
            message: "msg_response"
        )
        try fixture.event(
            "response-copy",
            type: "session.step.ended",
            cost: "0.012345",
            message: "msg_response"
        )
        try fixture.event("title", cost: "0.25")
        try fixture.event("compact", source: "compaction", cost: "0.5")
        try fixture.event(
            "failed",
            type: "session.step.failed.1",
            cost: "0.125",
            message: "msg_failed"
        )
        try fixture.message("msg_imported", cost: "1.5")
        let source = OpenCodeHistorySource(database: fixture.database)
        let before = try await source.read(request)
        XCTAssertEqual(before.observations.count, 5)
        XCTAssertEqual(summary(before).tokens, 1_000)
        XCTAssertEqual(summary(before).cost.usd, decimal("2.387345"))
        XCTAssertEqual(summary(before).cost.recordedOperations, 5)
        // Undo removes the projection, not the recorded spending (including its cost).
        try fixture.execute("DELETE FROM session_message WHERE id = 'msg_response'")
        let after = try await source.read(request)
        XCTAssertEqual(summary(after), summary(before))
        XCTAssertTrue(after.coverage.issues.isEmpty)
    }

    func testOpenCodeMissingAndInvalidCostsNeverDiscardTokensOrUseProjectionCost() async throws {
        for cost in [nil, "null", "-1", "1e100", #""1.25""#, "{}", "true"] as [String?] {
            let fixture = try OpenCodeHistoryFixture()
            try fixture.message(cost: "99")
            try fixture.event(type: "session.step.ended.1", cost: cost, message: "msg_response")
            let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
            XCTAssertEqual(result.observations.map(\.tokens), [200])
            XCTAssertNil(result.observations.first?.costUSD, "\(cost ?? "absent")")
            XCTAssertTrue(result.coverage.issues.isEmpty)
            XCTAssertEqual(summary(result).cost.display, "Unavailable")
        }
    }

    func testOpenCodeConflictingCostsStayUnavailableAcrossFurtherCopies() async throws {
        let fixture = try OpenCodeHistoryFixture()
        for (id, cost) in [("a", "1.25"), ("b", "2"), ("c", "1.25")] {
            try fixture.event(id, type: "session.step.ended.1", cost: cost, message: "msg_response")
        }
        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertEqual(result.observations.map(\.tokens), [200])
        XCTAssertNil(result.observations.first?.costUSD)
        XCTAssertTrue(result.coverage.issues.isEmpty)
    }

    func testZeroTokensCanStillCarryCost() async throws {
        let fixture = try OpenCodeHistoryFixture()
        try fixture.event(
            usage: OpenCodeHistoryFixture.tokens(
                input: 0,
                output: 0,
                reasoning: 0,
                read: 0,
                write: 0
            ),
            cost: "0.25"
        )
        let snapshot = try await HistoryService(adapters: [
            OpenCodeHistorySource(database: fixture.database)
        ])
        .refresh(now: request.now, calendar: request.calendar)
        XCTAssertEqual(snapshot.visibleSources.map(\.id), [.openCode])
        XCTAssertEqual(snapshot.sources.first?.summaries[.today]?.tokens, 0)
        XCTAssertEqual(snapshot.sources.first?.summaries[.today]?.cost.usd, decimal("0.25"))
    }

    func testPeriodCostsUseOperationDatesAndDistinguishPartialMissingAndZero() {
        let today = UsageObservation(
            operationID: "today",
            timestamp: request.now,
            tokens: 10,
            costUSD: decimal("0.001")
        )
        let yesterday = UsageObservation(
            operationID: "yesterday",
            timestamp: request.now.addingTimeInterval(-86_400),
            tokens: 20,
            costUSD: 2
        )
        let old = UsageObservation(
            operationID: "old",
            timestamp: request.now.addingTimeInterval(-10 * 86_400),
            tokens: 30
        )
        let future = UsageObservation(
            operationID: "future",
            timestamp: request.now.addingTimeInterval(1),
            tokens: 40,
            costUSD: 99
        )
        let summaries = historySummaries(
            [today, today, yesterday, old, future],
            now: request.now,
            calendar: request.calendar
        )
        XCTAssertEqual(summaries[.today]?.tokens, 10)
        XCTAssertEqual(summaries[.today]?.cost.usd, decimal("0.001"))
        XCTAssertEqual(summaries[.today]?.cost.display, "< $0.01")
        XCTAssertEqual(summaries[.week]?.cost.usd, decimal("2.001"))
        XCTAssertEqual(summaries[.week]?.cost.missingOperations, 0)
        XCTAssertEqual(summaries[.month]?.tokens, 60)
        XCTAssertEqual(summaries[.month]?.cost.recordedOperations, 2)
        XCTAssertEqual(summaries[.month]?.cost.missingOperations, 1)
        XCTAssertTrue(summaries[.month]!.cost.display.hasSuffix(" (partial)"))

        var zero = RecordedCostSummary()
        zero.add(0)
        XCTAssertEqual(zero.display, Decimal.zero.formatted(.currency(code: "USD")))
        var missing = RecordedCostSummary()
        missing.add(nil)
        XCTAssertEqual(missing.display, "Unavailable")
    }

    @MainActor
    func testLiveStorePublishesSelectedPeriodCostAndPreservesItAfterFailedRefresh() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), F.message(usage: piUsage(#"{"total":1.25}"#))])
        let source = PiHistorySource(root: fixture.root)
        let store = HistoryStore.live(adapters: [source], now: { F.now }, calendar: F.calendar)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.sources.first?.summaries[.today]?.cost.usd, decimal("1.25"))
        try fixture.write(lines: [F.header(), F.message(usage: piUsage(#"{"total":2.5}"#))])
        await store.refresh()
        for period in HistoryPeriod.allCases {
            store.period = period
            XCTAssertEqual(
                store.snapshot?.sources.first?.recordedCost(for: period),
                decimal("2.5").formatted(.currency(code: "USD"))
            )
        }
        // Replace the root with a non-directory: the accepted reading must remain available.
        try FileManager.default.removeItem(at: fixture.root)
        try Data().write(to: fixture.root)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.sources.first?.summaries[.today]?.cost.usd, decimal("2.5"))
        XCTAssertEqual(store.snapshot?.sources.first?.coverage?.state, .unavailable)
    }

    func testCodexAndUnreadableSourcesNeverDisplayZeroCost() {
        let summary = PeriodSummary.aggregate(
            [],
            period: .today,
            now: request.now,
            calendar: request.calendar
        )
        for (id, hasReadings, expected) in [
            (HistoryAgentID.codex, true, "Unavailable"),
            (.pi, false, "Unavailable"),
            (.openCode, true, Decimal.zero.formatted(.currency(code: "USD"))),
        ] {
            let source = HistorySourceSnapshot(
                id: id,
                summaries: [.today: summary],
                coverage: HistoryCoverage(
                    state: hasReadings ? .ready : .unavailable,
                    hasReadings: hasReadings,
                    issues: []
                ),
                fetchedAt: request.now,
                failed: !hasReadings
            )
            XCTAssertEqual(source.recordedCost(for: .today), expected)
        }
    }

    private func piUsage(_ cost: String?) -> String {
        "{\"input\":100,\"output\":20,\"cacheRead\":0,\"cacheWrite\":0\(cost.map { ",\"cost\":\($0)" } ?? "")}"
    }

    private func decimal(_ value: String) -> Decimal { Decimal(string: value)! }

    private func summary(_ result: HistoryAdapterResult) -> PeriodSummary {
        historySummaries(result.observations, now: request.now, calendar: request.calendar)[.month]!
    }
}
