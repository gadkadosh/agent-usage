import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testPeriodSwitchingChangesTotalAndBucketGranularityWithoutRefetch() async {
        let demo = DashboardDemo(scenario: "ready")
        let store = demo.makeHistoryStore()
        XCTAssertNil(store.snapshot)
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 18_420)
        XCTAssertEqual(store.summary?.buckets.count, 24)
        store.period = .week
        XCTAssertEqual(store.summary?.tokens, 331_560)
        XCTAssertEqual(store.summary?.buckets.count, 7)
        store.period = .month
        XCTAssertEqual(store.summary?.tokens, 1_657_800)
        XCTAssertEqual(store.summary?.buckets.count, 30)
    }

    func testAllowanceFailureDoesNotBlockHistoryAndHistoryFailureDoesNotChangeAllowance() async {
        let allowance = UsageStore(fetch: { throw SensitiveError() })
        let history = DashboardDemo(scenario: "ready").makeHistoryStore()
        await allowance.refresh()
        await history.refresh()
        XCTAssertNil(allowance.snapshot)
        XCTAssertNotNil(history.summary)
        XCTAssertNil(history.error)

        let workingAllowance = DashboardDemo(scenario: "ready").makeUsageStore()
        let failedHistory = HistoryStore(fetch: { throw SensitiveError() })
        await workingAllowance.refresh()
        await failedHistory.refresh()
        XCTAssertNotNil(workingAllowance.snapshot)
        XCTAssertNil(workingAllowance.error)
        XCTAssertNil(failedHistory.snapshot)
        XCTAssertFalse(failedHistory.error!.contains("private-secret"))
    }

    func testFailedHistoryRefreshKeepsLastSnapshotAndRecoveryClearsError() async {
        let fetcher = ScriptedHistory()
        let store = HistoryStore(fetch: { try await fetcher.fetch() })
        await store.refresh()
        let first = store.snapshot?.fetchedAt
        await store.refresh()
        XCTAssertEqual(store.snapshot?.fetchedAt, first)
        XCTAssertNotNil(store.summary)
        XCTAssertEqual(store.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh()
        XCTAssertNil(store.error)
    }

    func testOverlappingRefreshesOnlyFetchOnceAndCancellationIsNotError() async {
        let fetcher = SuspendedHistory()
        let store = HistoryStore(fetch: { try await fetcher.fetch() })
        let task = Task { await store.refresh() }
        await fetcher.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        let count = await fetcher.count
        XCTAssertEqual(count, 1)
        task.cancel()
        await fetcher.finish()
        await task.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.error)
    }

    func testDemoReadyPartialMissingAndStaleNeverNeedLiveSources() async {
        for scenario in ["ready", "partial", "missing", "stale"] {
            let demo = DashboardDemo(scenario: scenario)
            let history = demo.makeHistoryStore()
            let allowance = demo.makeUsageStore()
            await history.refresh()
            await allowance.refresh()
            XCTAssertEqual(history.snapshot?.fetchedAt, demo.now)
            XCTAssertEqual(allowance.snapshot?.fetchedAt, demo.now)
            if scenario == "missing" {
                XCTAssertFalse(history.snapshot!.coverage.hasReadings)
            }
            if scenario == "partial" {
                XCTAssertEqual(history.snapshot?.coverage.state, .partial)
            }
            if scenario == "stale" {
                await history.refresh()
                await allowance.refresh()
                XCTAssertNotNil(history.snapshot)
                XCTAssertNotNil(history.error)
                XCTAssertNotNil(allowance.snapshot)
                XCTAssertNotNil(allowance.error)
            }
        }
    }
}

private struct SensitiveError: LocalizedError {
    var errorDescription: String? { "/private/secret/path private-secret-payload" }
}

private actor ScriptedHistory {
    private var count = 0
    func fetch() throws -> HistorySnapshot {
        count += 1
        if count == 2 { throw SensitiveError() }
        return DashboardDemo(scenario: "ready").historySnapshot()
    }
}

private actor SuspendedHistory {
    private(set) var count = 0
    private var pending: CheckedContinuation<HistorySnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async throws -> HistorySnapshot {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: DashboardDemo(scenario: "ready").historySnapshot())
        pending = nil
    }
}
