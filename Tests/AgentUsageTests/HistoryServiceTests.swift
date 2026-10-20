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
        XCTAssertTrue(first.hasMoreFiles)
        let second = try await service.refresh(now: now, calendar: calendar)
        XCTAssertEqual(second.summaries[.today]?.tokens, 150)
        XCTAssertFalse(second.hasMoreFiles)
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
        XCTAssertNil(first.sources[1].coverage)
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

    private func observation(_ id: String, _ tokens: Int64) -> UsageObservation {
        UsageObservation(operationID: id, timestamp: now, tokens: tokens)
    }

    private func result(_ observations: [UsageObservation], more: Bool = false)
        -> HistoryAdapterResult
    {
        HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(state: .ready, issues: [], observedReadings: true),
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
