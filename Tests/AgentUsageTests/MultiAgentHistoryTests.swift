import Foundation
import XCTest

@testable import AgentUsage

final class MultiAgentHistoryTests: XCTestCase {
    func testFastSourcePublishesWhileAnotherSourceIsStillReading() async throws {
        let request = HistoryRequest(
            now: HistoryFixtures.now,
            calendar: HistoryFixtures.calendar
        )
        let piResult = result(tokens: 100)
        let codexResult = result(tokens: 200)
        let slow = DelayedHistoryAdapter(result: codexResult)
        let fast = ImmediateHistoryAdapter(result: piResult)
        let service = HistoryService(adapters: [fast, slow])
        let published = XCTestExpectation(description: "Pi is visible before Codex completes")
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            await slow.release()
        }
        defer { timeout.cancel() }
        let refresh = Task {
            try await service.refresh(now: request.now, calendar: request.calendar) { snapshot in
                if snapshot.summaries[.today]?.tokens == 100 {
                    XCTAssertTrue(snapshot.hasMore)
                    XCTAssertEqual(snapshot.visibleSources.map(\.id), [.pi])
                    published.fulfill()
                }
            }
        }
        let wait = await XCTWaiter.fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(wait, .completed)
        await slow.release()
        let final = try await refresh.value
        XCTAssertEqual(final.summaries[.today]?.tokens, 300)
        XCTAssertEqual(final.visibleSources.map(\.id), [.codex, .pi])
        XCTAssertFalse(final.hasMore)
    }

    func testRowsHideUnusedAndMissingSourcesButKeepZeroTodayAndFailedSources() {
        let now = HistoryFixtures.now
        let calendar = HistoryFixtures.calendar
        let old = UsageObservation(
            operationID: "old",
            timestamp: now.addingTimeInterval(-3 * 86400),
            tokens: 100
        )
        let summaries = historySummaries([old], now: now, calendar: calendar)
        let missing = HistorySourceSnapshot(
            id: .pi,
            summaries: historySummaries([], now: now, calendar: calendar),
            coverage: HistoryCoverage(state: .missing, hasReadings: false, issues: []),
            fetchedAt: now,
            failed: false
        )
        let codex = HistorySourceSnapshot(
            id: .codex,
            summaries: summaries,
            coverage: HistoryCoverage(state: .ready, hasReadings: true, issues: []),
            fetchedAt: now,
            failed: false
        )
        var snapshot = HistorySnapshot(
            summaries: summaries,
            coverage: codex.coverage!,
            fetchedAt: now,
            sources: [missing, codex]
        )
        XCTAssertEqual(snapshot.visibleSources.map(\.id), [.codex])
        XCTAssertEqual(snapshot.visibleSources[0].summaries[.today]?.tokens, 0)
        let failed = HistorySourceSnapshot(
            id: .pi,
            summaries: missing.summaries,
            coverage: nil,
            fetchedAt: nil,
            failed: true
        )
        snapshot.sources = [failed, codex]
        XCTAssertEqual(snapshot.visibleSources.map(\.id), [.codex, .pi])
        XCTAssertNotNil(snapshot.visibleSources[1].status)
        let unused = HistorySourceSnapshot(
            id: .pi,
            summaries: missing.summaries,
            coverage: codex.coverage,
            fetchedAt: now,
            failed: false
        )
        snapshot.sources = [unused]
        XCTAssertEqual(snapshot.visibleSources.count, 0)
    }

    func testAggregateOnlySnapshotDoesNotInventAnAgent() {
        let snapshot = HistorySnapshot(
            summaries: historySummaries(
                [
                    UsageObservation(
                        operationID: "aggregate",
                        timestamp: HistoryFixtures.now,
                        tokens: 100
                    )
                ],
                now: HistoryFixtures.now,
                calendar: HistoryFixtures.calendar
            ),
            coverage: HistoryCoverage(state: .ready, hasReadings: true, issues: []),
            fetchedAt: HistoryFixtures.now,
            sources: []
        )
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 100)
        XCTAssertTrue(snapshot.visibleSources.isEmpty)
    }

    func testPartialAndStaleStatusBelongsToTheAgent() {
        let source = HistorySourceSnapshot(
            id: .codex,
            summaries: [:],
            coverage: HistoryCoverage(
                state: .partial,
                hasReadings: true,
                issues: [.unreadableFile, .staleFile]
            ),
            fetchedAt: HistoryFixtures.now,
            failed: false
        )
        XCTAssertEqual(source.status, "Incomplete history. Includes older readings.")
    }

    private func result(tokens: Int64) -> HistoryAdapterResult {
        HistoryAdapterResult(
            observations: [
                UsageObservation(
                    operationID: "same",
                    timestamp: HistoryFixtures.now,
                    tokens: tokens
                )
            ],
            coverage: HistoryCoverage(state: .ready, hasReadings: true, issues: []),
            fetchedAt: HistoryFixtures.now
        )
    }
}

private struct ImmediateHistoryAdapter: HistoryAdapter {
    let id = HistoryAgentID.pi
    let result: HistoryAdapterResult
    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult { result }
}

private actor DelayedHistoryAdapter: HistoryAdapter {
    nonisolated let id = HistoryAgentID.codex
    private let result: HistoryAdapterResult
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    init(result: HistoryAdapterResult) { self.result = result }
    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult {
        if !released { await withCheckedContinuation { pending = $0 } }
        return result
    }
    func release() {
        released = true
        pending?.resume()
        pending = nil
    }
}
