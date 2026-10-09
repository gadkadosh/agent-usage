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

    func testOverlapJoinsOwnedScanAndCallerCancellationDoesNotDiscardResult() async {
        let gate = HistoryGate()
        let store = HistoryStore(fetch: { historySnapshot(read: await gate.pause()) })
        let first = Task { await store.refresh() }
        defer { Task { await gate.resume() } }
        guard await gate.waitUntilPaused() else { return }
        let joined = Task { await store.refresh() }
        first.cancel()
        await gate.resume()
        await first.value
        await joined.value
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    func testAlreadyCancelledRequestDoesNotStartOrSuppressLaterRefresh() async {
        let fetcher = ScriptedHistory()
        let store = HistoryStore(fetch: { try await fetcher.fetch() })
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh()
        }
        await request.value
        var count = await fetcher.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh()
        count = await fetcher.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertNil(store.error)
    }

    func testStartupReturnsBeforeIOAndIsIdempotentAfterCompletion() async {
        let gate = HistoryGate()
        let store = HistoryStore(fetch: { historySnapshot(read: await gate.pause()) })
        store.start()
        store.start()
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.snapshot)
        defer { Task { await gate.resume() } }
        guard await gate.waitUntilPaused() else { return }
        let joined = Task { await store.refresh() }
        await gate.resume()
        await joined.value
        store.start()
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertFalse(store.isRefreshing)
    }

    func testStartupPublishesIntermediateBatchAndCatchesUpWithoutPanel() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let lines = [PiHistoryFixtures.header(), PiHistoryFixtures.message()]
        let first = try fixture.write("a.jsonl", lines: lines)
        // Distinct operation IDs, but identical file sizes, keep exactly one file per batch.
        try fixture.write(
            "b.jsonl",
            lines: [
                PiHistoryFixtures.header(), PiHistoryFixtures.message(id: "operation-b"),
            ]
        )
        let size = try Data(contentsOf: first).count
        let source = PiHistorySource(root: fixture.root, limits: .init(refreshBytes: size))
        let gate = HistoryGate()
        let store = HistoryStore(fetch: {
            let result = try await source.refresh(
                now: PiHistoryFixtures.now,
                calendar: PiHistoryFixtures.calendar
            )
            if !result.hasMoreFiles { await gate.pause() }
            return result
        })
        store.start()
        defer { Task { await gate.resume() } }
        guard await gate.waitUntilPaused() else { return }
        XCTAssertEqual(store.summary?.tokens, 190)
        XCTAssertEqual(store.snapshot?.hasMoreFiles, true)
        XCTAssertEqual(store.snapshot?.coverage.issues, [])
        XCTAssertTrue(store.isRefreshing)
        let joined = Task { await store.refresh() }
        await gate.resume()
        await joined.value
        XCTAssertEqual(store.summary?.tokens, 380)
        XCTAssertEqual(store.snapshot?.hasMoreFiles, false)
        XCTAssertFalse(store.isRefreshing)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)
    }

    func testCatchUpFailureKeepsIntermediateReadingAndManualRefreshRecovers() async {
        let fetcher = ScriptedHistory()
        let store = HistoryStore(fetch: {
            var snapshot = try await fetcher.fetch()
            snapshot.hasMoreFiles = snapshot.fetchedAt == historySnapshot().fetchedAt
            return snapshot
        })
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 100)
        XCTAssertEqual(store.snapshot?.hasMoreFiles, true)
        XCTAssertEqual(store.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 300)
        XCTAssertEqual(store.snapshot?.hasMoreFiles, false)
        XCTAssertNil(store.error)
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
