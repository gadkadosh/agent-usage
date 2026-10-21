import Combine
import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryRefreshTests: XCTestCase {
    func testLiveStorePublishesFastSourceWhileAnotherIsStillReading() async throws {
        let gate = HistoryGate("Slow adapter")
        let fast = ClosureHistoryAdapter(id: .pi) { request in reading(100, request) }
        let slow = ClosureHistoryAdapter(id: .init(rawValue: "slow")) { request in
            await gate.pause()
            return reading(200, request)
        }
        let store = HistoryStore.live(
            adapters: [fast, slow],
            now: { PiHistoryFixtures.now },
            calendar: PiHistoryFixtures.calendar
        )
        let published = XCTestExpectation(description: "Fast source reaches the live store")
        let subscription = store.$snapshot.compactMap { $0 }.first {
            $0.summaries[.today]?.tokens == 100
        }.sink { _ in published.fulfill() }
        defer {
            subscription.cancel()
            Task { await gate.resume() }
        }
        store.start()
        guard await gate.waitUntilPaused() else { return }
        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(store.snapshot?.hasMore, true)
        XCTAssertEqual(store.snapshot?.sources.map(\.isLoading), [false, true])
        await gate.resume()
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 300)
        XCTAssertEqual(store.snapshot?.hasMore, false)
        XCTAssertFalse(store.isRefreshing)
        let slowReads = await gate.count
        XCTAssertEqual(slowReads, 1, "Joining the active refresh must not read again")
    }

    func testLiveStoreKeepsPublishedDataWhenSlowSourceFailsAndThenRecovers() async throws {
        let gate = HistoryGate("Failing adapter")
        let fast = ClosureHistoryAdapter(id: .pi) { request in reading(100, request) }
        let slow = ClosureHistoryAdapter(id: .init(rawValue: "slow")) { request in
            let call = await gate.pause()
            if call == 1 { throw HistoryReadError.unavailable }
            return reading(200, request)
        }
        let store = HistoryStore.live(
            adapters: [fast, slow],
            now: { PiHistoryFixtures.now },
            calendar: PiHistoryFixtures.calendar
        )
        let published = XCTestExpectation(description: "Available data is published before failure")
        let subscription = store.$snapshot.compactMap { $0 }.first {
            $0.summaries[.today]?.tokens == 100
        }.sink { _ in published.fulfill() }
        defer {
            subscription.cancel()
            Task { await gate.resume() }
        }
        store.start()
        guard await gate.waitUntilPaused() else { return }
        await fulfillment(of: [published], timeout: 5)
        await gate.resume()
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertEqual(store.snapshot?.coverage.state, .partial)
        XCTAssertEqual(store.snapshot?.sources[1].coverage?.state, .unavailable)
        XCTAssertEqual(store.snapshot?.sources[1].coverage?.hasReadings, false)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isRefreshing)

        let recovery = Task { await store.refresh() }
        guard await gate.waitUntilPaused() else { return }
        await gate.resume()
        await recovery.value
        XCTAssertEqual(store.summary?.tokens, 300)
        XCTAssertEqual(store.snapshot?.coverage.state, .ready)
        XCTAssertNil(store.error)
    }

    func testRealPiReaderRetainsUnsupportedHistoryThenClearsConfirmedDeletion() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [
            PiHistoryFixtures.header(), PiHistoryFixtures.message(),
        ])
        let store = HistoryStore.live(
            root: fixture.root,
            now: { PiHistoryFixtures.now },
            calendar: PiHistoryFixtures.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 190)
        try Data("{\"type\":\"session\",\"version\":999,\"id\":\"unsupported\"}\n".utf8).write(
            to: file,
            options: .atomic
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 190)
        XCTAssertEqual(store.snapshot?.sources[0].coverage?.state, .unsupported)
        XCTAssertEqual(store.snapshot?.sources[0].failed, true)
        XCTAssertNotNil(store.error)
        try FileManager.default.removeItem(at: file)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.coverage.state, .missing)
        XCTAssertEqual(store.snapshot?.coverage.hasReadings, false)
        XCTAssertEqual(store.summary?.tokens, 0)
        XCTAssertNil(store.error)
    }
}

private struct ClosureHistoryAdapter: HistoryAdapter {
    let id: HistoryAgentID
    let operation: @Sendable (HistoryRequest) async throws -> HistoryAdapterResult
    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult {
        try await operation(request)
    }
}

private func reading(_ tokens: Int64, _ request: HistoryRequest) -> HistoryAdapterResult {
    HistoryAdapterResult(
        observations: [
            UsageObservation(operationID: "same", timestamp: request.now, tokens: tokens)
        ],
        coverage: HistoryCoverage(state: .ready, hasReadings: true, issues: []),
        fetchedAt: request.now
    )
}
