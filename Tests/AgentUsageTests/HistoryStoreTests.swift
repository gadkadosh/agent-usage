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
                store.summary?.tokens,
                period == .today ? 100 : period == .week ? 200 : 300
            )
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
                    secondaryWindow: .init(usedPercent: 50, resetAfterSeconds: 600)
                )
            )
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
        let finished = expectation(description: "Cancelled refresh finishes")
        let task = Task {
            await store.refresh()
            finished.fulfill()
        }
        defer {
            task.cancel()
            Task { await gate.resume() }
        }
        guard await gate.waitUntilPaused() else { return }
        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        let count = await fetcher.count
        XCTAssertEqual(count, 3)
        task.cancel()
        await gate.resume()
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(completion, .completed)
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

    func testReopenWaitsForCancelledScanThenPublishesNewReading() async {
        let gate = HistoryGate()
        let store = HistoryStore(fetch: { historySnapshot(read: await gate.pause()) })
        let first = Task { await store.refresh() }
        defer {
            first.cancel()
            Task { await gate.resume() }
        }
        guard await gate.waitUntilPaused() else { return }
        first.cancel()

        let waiting = expectation(description: "Reopen waits for the cancelled scan")
        let reopened = Task {
            waiting.fulfill()
            await store.refreshWhenIdle()
        }
        defer { reopened.cancel() }
        let started = await XCTWaiter.fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(started, .completed)
        var count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.snapshot)

        await gate.resume()
        await first.value
        guard await gate.waitUntilPaused() else { return }
        count = await gate.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.snapshot, "The cancelled scan must not publish its late result")
        XCTAssertNil(store.error)

        await gate.resume()
        await reopened.value
        XCTAssertEqual(store.snapshot?.fetchedAt, historySnapshot(read: 2).fetchedAt)
        XCTAssertEqual(store.summary, historySnapshot(read: 2).summaries[.today])
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    func testCancelledReopenDoesNotFetchAfterInFlightScanCompletes() async {
        let gate = HistoryGate()
        let store = HistoryStore(fetch: { historySnapshot(read: await gate.pause()) })
        let first = Task { await store.refresh() }
        defer {
            first.cancel()
            Task { await gate.resume() }
        }
        guard await gate.waitUntilPaused() else { return }

        let waiting = expectation(description: "Reopen waits for the in-flight scan")
        let reopened = Task {
            waiting.fulfill()
            await store.refreshWhenIdle()
        }
        defer { reopened.cancel() }
        let started = await XCTWaiter.fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(started, .completed)
        reopened.cancel()
        await gate.resume()
        await first.value
        await reopened.value

        let count = await gate.count
        XCTAssertEqual(count, 1, "A panel closed while waiting must not start another scan")
        XCTAssertEqual(store.summary, historySnapshot().summaries[.today])
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
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
                tokens: Int64(read * 100)
            )
        } : []
    return HistorySnapshot(
        summaries: Dictionary(
            uniqueKeysWithValues: HistoryPeriod.allCases.map {
                (
                    $0,
                    PeriodSummary.aggregate(observations, period: $0, now: now, calendar: calendar)
                )
            }
        ),
        coverage: HistoryCoverage(
            state: state,
            filesRead: readable ? 1 : 0,
            issues: state == .partial ? [.unreadableFile] : []
        ),
        fetchedAt: now
    )
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

/// Non-cooperative suspension for late-result tests, with bounded failures instead of hangs.
private actor HistoryGate {
    private(set) var count = 0
    private let name: String
    private var pending: CheckedContinuation<Void, Never>?
    private var started: XCTestExpectation?

    init(_ name: String = "History") { self.name = name }

    @discardableResult
    func pause(file: StaticString = #filePath, line: UInt = #line) async -> Int {
        guard pending == nil else {
            XCTFail(
                "\(name): overlapping pauses would overwrite a continuation",
                file: file,
                line: line
            )
            return count
        }
        count += 1
        let call = count
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard count == call, pending != nil else { return }
            XCTFail("\(name): pause wasn't released within 5 seconds", file: file, line: line)
            resume()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation {
            pending = $0
            started?.fulfill()
            started = nil
        }
        return call
    }

    func waitUntilPaused(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if pending != nil { return true }
        guard started == nil else {
            XCTFail("\(name): only one observer may wait for a pause", file: file, line: line)
            return false
        }
        let expectation = XCTestExpectation(description: "\(name) reaches pause")
        started = expectation
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        if started === expectation { started = nil }
        XCTAssertEqual(result, .completed, "\(name): pause wasn't reached", file: file, line: line)
        return result == .completed
    }

    func resume() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}
