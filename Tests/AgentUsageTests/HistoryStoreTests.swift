import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testPeriodSelectionUsesSnapshotWithoutRefetch() async {
        let fetcher = ScriptedHistory()
        let store = HistoryStore(fetch: { try await fetcher.fetch() })
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.summary)
        XCTAssertEqual(store.period, .today)

        await store.refresh()
        for period in HistoryPeriod.allCases {
            store.period = period
            XCTAssertEqual(store.summary, historySnapshot().summaries[period])
            XCTAssertEqual(
                store.summary?.tokens, period == .today ? 100 : period == .week ? 200 : 300)
            XCTAssertEqual(store.summary?.buckets.count, period == .today ? 24 : period.rawValue)
        }
        let count = await fetcher.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.snapshot?.coverage, historySnapshot().coverage)
        XCTAssertEqual(store.snapshot?.fetchedAt, historySnapshot().fetchedAt)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    func testInitialFailureIsUnavailableNotZeroAndDoesNotLeakError() async {
        let store = HistoryStore(fetch: { throw SensitiveError() })
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.summary)
        XCTAssertEqual(store.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertFalse(store.error!.contains("private-secret"))
        XCTAssertFalse(store.isRefreshing)
    }

    func testEnumerationFailurePreservesSnapshotAndRecoveryClearsError() async {
        let fetcher = ScriptedHistory()
        let store = HistoryStore(fetch: { try await fetcher.fetch() })
        await store.refresh()
        await store.refresh()  // The source rejects an enumeration failure.
        XCTAssertEqual(store.snapshot?.fetchedAt, historySnapshot().fetchedAt)
        XCTAssertEqual(store.snapshot?.coverage, historySnapshot().coverage)
        XCTAssertEqual(store.summary, historySnapshot().summaries[.today])
        XCTAssertEqual(store.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.fetchedAt, historySnapshot(read: 3).fetchedAt)
        XCTAssertEqual(store.summary, historySnapshot(read: 3).summaries[.today])
        XCTAssertNil(store.error)
    }

    func testCoverageStatesArePublishedWithoutInventingReadings() async {
        for state in [HistoryCoverage.State.ready, .partial, .missing, .unavailable, .unsupported] {
            let snapshot = historySnapshot(state: state)
            let store = HistoryStore(fetch: { snapshot })
            await store.refresh()
            XCTAssertEqual(store.snapshot?.coverage, snapshot.coverage)
            XCTAssertEqual(store.snapshot?.summaries, snapshot.summaries)
            XCTAssertNil(store.error)
        }
    }

    func testAllowanceAndHistoryFailuresAreIndependent() async {
        let allowance = UsageStore(fetch: { throw SensitiveError() })
        let history = HistoryStore(fetch: { historySnapshot() })
        await allowance.refresh()
        await history.refresh()
        XCTAssertNil(allowance.snapshot)
        XCTAssertNotNil(allowance.error)
        XCTAssertNotNil(history.snapshot)
        XCTAssertNil(history.error)

        let workingAllowance = UsageStore(fetch: {
            UsageLimits(
                rateLimit: .init(
                    primaryWindow: .init(usedPercent: 25, resetAfterSeconds: 300),
                    secondaryWindow: .init(usedPercent: 50, resetAfterSeconds: 600)))
        })
        let failedHistory = HistoryStore(fetch: { throw SensitiveError() })
        await workingAllowance.refresh()
        await failedHistory.refresh()
        XCTAssertNotNil(workingAllowance.snapshot)
        XCTAssertNil(workingAllowance.error)
        XCTAssertNil(failedHistory.snapshot)
        XCTAssertNotNil(failedHistory.error)
    }

    func testOverlapAndCancelledLateResultPreservePreviousSnapshotAndError() async {
        let fetcher = ScriptedHistory()
        let gate = HistoryGate()
        let store = HistoryStore(fetch: {
            let result = try await fetcher.fetch()
            if result.fetchedAt == historySnapshot(read: 3).fetchedAt { await gate.pause() }
            return result
        })
        await store.refresh()
        await store.refresh()
        let task = Task { await store.refresh() }
        await gate.waitUntilPaused()
        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        let count = await fetcher.count
        XCTAssertEqual(count, 3)
        task.cancel()
        await gate.resume()
        await task.value
        XCTAssertEqual(store.snapshot?.fetchedAt, historySnapshot().fetchedAt)
        XCTAssertEqual(store.summary, historySnapshot().summaries[.today])
        XCTAssertEqual(store.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertFalse(store.isRefreshing)
    }

    func testCancellationErrorDoesNotBecomeSourceFailure() async {
        let store = HistoryStore(fetch: { throw CancellationError() })
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    func testPollingStartsOnceRefreshesAgainAndCanRestartAfterStop() async {
        let fetchGate = HistoryGate()
        let sleepGate = HistoryGate()
        let store = HistoryStore(
            fetch: {
                await fetchGate.pause()
                return historySnapshot()
            },
            sleep: { interval in
                XCTAssertEqual(interval, .seconds(120))
                await sleepGate.pause()
                try Task.checkCancellation()
            })
        store.start(refreshInterval: .seconds(120))
        await fetchGate.waitUntilPaused()
        store.start(refreshInterval: .seconds(120))
        var count = await fetchGate.count
        XCTAssertEqual(count, 1)
        await fetchGate.resume()
        await sleepGate.waitUntilPaused()
        XCTAssertNotNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)

        await sleepGate.resume()
        await fetchGate.waitUntilPaused()
        count = await fetchGate.count
        XCTAssertEqual(count, 2)
        await fetchGate.resume()
        await sleepGate.waitUntilPaused()
        store.stop()
        store.stop()
        await sleepGate.resume()

        store.start(refreshInterval: .seconds(120))
        await fetchGate.waitUntilPaused()
        count = await fetchGate.count
        XCTAssertEqual(count, 3)
        await fetchGate.resume()
        await sleepGate.waitUntilPaused()
        store.stop()
        await sleepGate.resume()
    }
}

/// Numeric-only fixtures; no demo, discovery, home directory, credentials or network access.
private func historySnapshot(read: Int = 1, state: HistoryCoverage.State = .ready)
    -> HistorySnapshot
{
    let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(read - 1) * 60)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let readable = state == .ready || state == .partial
    let observations =
        readable
        ? [0, 3, 20].map {
            UsageObservation(
                operationID: "synthetic-\($0)",
                timestamp: calendar.date(byAdding: .day, value: -$0, to: now)!,
                tokens: Int64(read * 100))
        } : []
    return HistorySnapshot(
        summaries: Dictionary(
            uniqueKeysWithValues: HistoryPeriod.allCases.map {
                (
                    $0,
                    PeriodSummary.aggregate(observations, period: $0, now: now, calendar: calendar)
                )
            }),
        coverage: HistoryCoverage(
            state: state, filesRead: readable ? 1 : 0,
            issues: state == .partial ? [.unreadableFile] : []),
        fetchedAt: now)
}

private struct SensitiveError: LocalizedError {
    var errorDescription: String? { "/private-secret/path private-secret-payload" }
}

private actor ScriptedHistory {
    private(set) var count = 0
    func fetch() throws -> HistorySnapshot {
        count += 1
        if count == 2 { throw HistoryReadError.unavailable }
        return historySnapshot(read: count)
    }
}

/// A deliberately non-cooperative suspension to test late results after cancellation.
private actor HistoryGate {
    private(set) var count = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func pause() async {
        count += 1
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        pending?.resume()
        pending = nil
    }
}
