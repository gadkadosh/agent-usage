import Foundation
import XCTest

@testable import AgentUsage

final class HistoryServiceTests: XCTestCase {
    private let now = PiHistoryFixtures.now
    private let calendar = PiHistoryFixtures.calendar

    func testReplacementCorrectsAndRemovesRecordsRatherThanAppending() async throws {
        let adapter = ScriptedAdapter(
            id: .pi,
            results: [
                result([observation("a", 100), observation("b", 200)], more: true),
                result([observation("a", 150)]),
                result([]),
            ]
        )
        let service = HistoryService(adapters: [adapter])
        let first = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(first.summaries[.today]?.tokens, 300)
        XCTAssertTrue(first.hasMore)
        let second = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(second.summaries[.today]?.tokens, 150)
        XCTAssertFalse(second.hasMore)
        let third = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(third.summaries[.today]?.tokens, 0)
        XCTAssertTrue(third.coverage.hasReadings)
    }

    func testFailureRetainsObservationsButRebucketsThemAcrossMidnightAndRecovers() async throws {
        let adapter = ScriptedAdapter(
            id: .pi,
            results: [
                result([observation("a", 100)]), nil, result([observation("b", 200)]),
            ]
        )
        let service = HistoryService(adapters: [adapter])
        _ = try await service.refresh(now: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let stale = try await service.refresh(now: tomorrow, calendar: calendar)
        XCTAssertEqual(stale.summaries[.today]?.tokens, 0)
        XCTAssertEqual(stale.summaries[.week]?.tokens, 100)
        XCTAssertEqual(stale.fetchedAt, now)
        XCTAssertTrue(stale.sources[0].failed)
        XCTAssertNotNil(stale.refreshError)
        let recovered = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 200)
        XCTAssertFalse(recovered.sources[0].failed)
        XCTAssertNil(recovered.refreshError)
    }

    func testSourcesWithSameOperationIdentityStayIndependentDuringFailureAndRecovery() async throws
    {
        let pi = ScriptedAdapter(
            id: .pi,
            results: [
                result([observation("same", 100)]), nil, result([observation("same", 150)]),
            ]
        )
        let other = ScriptedAdapter(
            id: .init(rawValue: "synthetic"),
            results: [
                nil, result([observation("same", 200)]), result([observation("same", 300)]),
            ]
        )
        let service = HistoryService(adapters: [pi, other])
        let first = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(first.summaries[.today]?.tokens, 100)
        XCTAssertEqual(first.sources[1].coverage?.state, .unavailable)
        XCTAssertNil(first.sources[1].fetchedAt)
        XCTAssertTrue(first.sources[1].failed)
        let second = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(second.summaries[.today]?.tokens, 300)
        XCTAssertTrue(second.sources[0].failed)
        XCTAssertFalse(second.sources[1].failed)
        for period in HistoryPeriod.allCases {
            let summary = try XCTUnwrap(second.summaries[period])
            XCTAssertEqual(summary.tokens, summary.buckets.reduce(0) { $0 + $1.tokens })
            XCTAssertEqual(
                summary.tokens,
                second.sources.reduce(0) {
                    $0 + ($1.summaries[period]?.tokens ?? 0)
                }
            )
        }
        let third = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(third.summaries[.today]?.tokens, 450)
        XCTAssertNil(third.refreshError)
    }

    func testInitialFailureDoesNotInventZeroAndRecoveryUsesRequestedWindow() async throws {
        let adapter = ScriptedAdapter(id: .pi, results: [nil, result([observation("a", 100)])])
        let service = HistoryService(adapters: [adapter])
        do {
            _ = try await service.refresh(now: now, calendar: calendar)
            XCTFail("Initial failure should not return an observed zero")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                HistoryReadError.unavailable.localizedDescription
            )
        }
        let snapshot = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 100)
        let requests = await adapter.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.since, HistoryPeriod.month.start(at: now, calendar: calendar))
    }

    func testUnreadableResultsRetainUsageUntilAValidReplacementOrConfirmedDeletion() async throws {
        for state in [HistoryCoverage.State.unsupported, .unavailable, .partial] {
            let unusable = HistoryAdapterResult(
                observations: [],
                coverage: HistoryCoverage(
                    state: state,
                    hasReadings: false,
                    issues: [.unsupportedVersion]
                ),
                fetchedAt: now.addingTimeInterval(60),
                hasMore: true  // Failed/unusable results must never schedule retries.
            )
            let adapter = ScriptedAdapter(
                id: .pi,
                results: [
                    result([observation("a", 200)]), unusable, result([]),
                    result([observation("b", 300)]),
                    HistoryAdapterResult(
                        observations: [],
                        coverage: HistoryCoverage(state: .missing, hasReadings: false, issues: []),
                        fetchedAt: now
                    ),
                ]
            )
            let service = HistoryService(adapters: [adapter])
            _ = try await service.refresh(now: now, calendar: calendar)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            let stale = try await service.refresh(now: tomorrow, calendar: calendar)
            XCTAssertEqual(stale.summaries[.today]?.tokens, 0)
            XCTAssertEqual(stale.summaries[.week]?.tokens, 200)
            XCTAssertEqual(stale.sources[0].coverage?.state, state)
            XCTAssertEqual(stale.sources[0].coverage?.hasReadings, true)
            XCTAssertEqual(stale.sources[0].fetchedAt, now)
            XCTAssertTrue(stale.sources[0].failed)
            XCTAssertFalse(stale.hasMore)
            XCTAssertEqual(stale.coverage.state, .partial)

            let empty = try await service.refresh(now: now, calendar: calendar)
            XCTAssertEqual(empty.summaries[.week]?.tokens, 0)
            XCTAssertTrue(empty.coverage.hasReadings)
            XCTAssertEqual(empty.coverage.state, .ready)
            XCTAssertFalse(empty.sources[0].failed)
            XCTAssertNil(empty.refreshError)
            let recovered = try await service.refresh(now: now, calendar: calendar)
            XCTAssertEqual(recovered.summaries[.today]?.tokens, 300)
            let deleted = try await service.refresh(now: now, calendar: calendar)
            XCTAssertEqual(deleted.summaries[.week]?.tokens, 0)
            XCTAssertEqual(deleted.coverage.state, .missing)
            XCTAssertFalse(deleted.coverage.hasReadings)
            XCTAssertNil(deleted.refreshError)
        }
    }

    func testUsablePartialResultReplacesInsteadOfKeepingDeletedOrCorrectedRecords() async throws {
        let partial = HistoryAdapterResult(
            observations: [observation("a", 50)],
            coverage: HistoryCoverage(state: .partial, hasReadings: true, issues: [.invalidUsage]),
            fetchedAt: now
        )
        let service = HistoryService(adapters: [
            ScriptedAdapter(
                id: .pi,
                results: [
                    result([observation("a", 100), observation("b", 200)]), partial,
                ]
            )
        ])
        _ = try await service.refresh(now: now, calendar: calendar)
        let snapshot = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 50)
        XCTAssertEqual(snapshot.coverage.state, .partial)
        XCTAssertEqual(snapshot.coverage.issues, [.invalidUsage])
        XCTAssertFalse(snapshot.sources[0].failed)
        XCTAssertNil(snapshot.refreshError)
    }

    func testCoverageDistinguishesMissingSourcesFromZeroAndUnavailableMeasurements() async throws {
        let cases: [(HistoryCoverage.State, HistoryCoverage.State, HistoryCoverage.State, Bool)] = [
            (.ready, .missing, .ready, true),
            (.missing, .ready, .ready, true),
            (.missing, .missing, .missing, false),
            (.ready, .unsupported, .partial, true),
            (.ready, .unavailable, .partial, true),
            (.unsupported, .missing, .unsupported, false),
            (.unavailable, .missing, .unavailable, false),
            (.unsupported, .unavailable, .unavailable, false),
        ]
        for (first, second, expected, measured) in cases {
            let adapters = [first, second].enumerated().map { index, state in
                ScriptedAdapter(
                    id: .init(rawValue: "source-\(index)"),
                    results: [
                        HistoryAdapterResult(
                            observations: [],
                            coverage: HistoryCoverage(
                                state: state,
                                hasReadings: state == .ready,
                                issues: []
                            ),
                            fetchedAt: now
                        )
                    ]
                )
            }
            let snapshot = try await HistoryService(adapters: adapters).refresh(
                now: now,
                calendar: calendar
            )
            XCTAssertEqual(snapshot.coverage.state, expected, "\(first) + \(second)")
            XCTAssertEqual(snapshot.coverage.hasReadings, measured)
            XCTAssertEqual(snapshot.summaries[.today]?.tokens, 0)
            XCTAssertEqual(snapshot.sources.map { $0.coverage?.state }, [first, second])
        }
    }

    func testCatchUpReadsOnlyPendingAdaptersWithOneClockAndCalendar() async throws {
        let advancing = ScriptedAdapter(
            id: .pi,
            results: [
                result([observation("a", 100)], more: true), result([observation("a", 150)]),
                result([]),
            ]
        )
        let completed = ScriptedAdapter(
            id: .init(rawValue: "done"),
            results: [
                result([observation("a", 200)]), result([]),
            ]
        )
        let failing = ScriptedAdapter(id: .init(rawValue: "failed"), results: [nil, result([])])
        let service = HistoryService(adapters: [advancing, completed, failing])
        let first = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(first.summaries[.today]?.tokens, 300)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.sources.map(\.isLoading), [true, false, false])
        var changedCalendar = calendar
        changedCalendar.timeZone = TimeZone(secondsFromGMT: 12 * 3600)!
        let later = now.addingTimeInterval(86_400)
        let final = try await service.refresh(now: later, calendar: changedCalendar)
        XCTAssertEqual(final.summaries[.today]?.tokens, 350)
        XCTAssertFalse(final.hasMore)
        XCTAssertTrue(final.sources[2].failed)
        let requests = await advancing.requests
        let completedRequests = await completed.requests
        let failedRequests = await failing.requests
        XCTAssertEqual(requests.map(\.now), [now, now])
        XCTAssertEqual(requests.map(\.calendar), [calendar, calendar])
        XCTAssertEqual(
            requests.map(\.since),
            [
                HistoryPeriod.month.start(at: now, calendar: calendar),
                HistoryPeriod.month.start(at: now, calendar: calendar),
            ]
        )
        XCTAssertEqual(completedRequests.count, 1)
        XCTAssertEqual(failedRequests.count, 1)
        let next = try await service.refresh(now: later, calendar: changedCalendar)
        XCTAssertFalse(next.hasMore)
        XCTAssertNil(next.refreshError)
        let nextRequests = await advancing.requests
        XCTAssertEqual(nextRequests.last?.now, later)
        XCTAssertEqual(nextRequests.last?.calendar, changedCalendar)
    }

    func testFailedContinuationStopsCatchUpAndManualRefreshRecovers() async throws {
        let adapter = ScriptedAdapter(
            id: .pi,
            results: [
                result([observation("a", 100)], more: true), nil, result([observation("a", 200)]),
            ]
        )
        let service = HistoryService(adapters: [adapter])
        _ = try await service.refresh(now: now, calendar: calendar)
        let stopped = try await service.refresh(now: now, calendar: calendar)
        XCTAssertFalse(stopped.hasMore)
        XCTAssertEqual(stopped.summaries[.today]?.tokens, 100)
        XCTAssertTrue(stopped.sources[0].failed)
        let recovered = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 200)
        XCTAssertNil(recovered.refreshError)
    }

    private func observation(_ id: String, _ tokens: Int64) -> UsageObservation {
        UsageObservation(operationID: id, timestamp: now, tokens: tokens)
    }

    private func result(_ observations: [UsageObservation], more: Bool = false)
        -> HistoryAdapterResult
    {
        HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(state: .ready, hasReadings: true, issues: []),
            fetchedAt: now,
            hasMore: more
        )
    }
}

private actor ScriptedAdapter: HistoryAdapter {
    nonisolated let id: HistoryAgentID
    private var results: [HistoryAdapterResult?]
    private(set) var requests: [HistoryRequest] = []

    init(id: HistoryAgentID, results: [HistoryAdapterResult?]) {
        self.id = id
        self.results = results
    }

    func read(_ request: HistoryRequest) throws -> HistoryAdapterResult {
        requests.append(request)
        guard !results.isEmpty, let result = results.removeFirst() else {
            throw NSError(domain: "/private/sensitive-payload", code: 1)
        }
        return result
    }
}
