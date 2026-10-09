import XCTest

@testable import AgentUsage

@MainActor
final class HistoryPanelLifecycleTests: XCTestCase {
    func testHiddenPanelDoesNotScanAndDuplicateVisibleNotificationsDoNotRescan() async {
        let fetched = expectation(description: "Panel opens")
        let readings = DashboardReadings()
        let history = HistoryStore(fetch: {
            let value = try await readings.history()
            fetched.fulfill()
            return value
        })
        let view = HistoryPanelLifecycle.TrackingView(history: history)
        view.setVisible(false)
        let before = await readings.counts
        XCTAssertEqual(before, [0, 0])
        view.setVisible(true)
        view.setVisible(true)
        let result = await XCTWaiter.fulfillment(of: [fetched], timeout: 5)
        XCTAssertEqual(result, .completed)
        let after = await readings.counts
        XCTAssertEqual(after, [0, 1])
        view.setVisible(false)
    }

    func testClosingPanelDoesNotCancelManualRefresh() async {
        let started = expectation(description: "Manual scan pauses")
        let gate = PanelScanGate()
        let readings = DashboardReadings()
        let history = HistoryStore(fetch: {
            let value = try await readings.history()
            await gate.pause(started: started)
            return value
        })
        let view = HistoryPanelLifecycle.TrackingView(history: history)
        let finished = expectation(description: "Manual refresh finishes while hidden")
        let manual = Task {
            await history.refresh()
            finished.fulfill()
        }
        defer {
            manual.cancel()
            view.setVisible(false)
            Task { await gate.release() }
        }
        let start = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(start, .completed)
        guard start == .completed else { return }
        view.setVisible(true)
        view.setVisible(false)
        XCTAssertTrue(history.isRefreshing)
        XCTAssertNil(history.snapshot)

        await gate.release()
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(completion, .completed)
        XCTAssertEqual(history.summary?.tokens, 18_420)
        XCTAssertNil(history.error)
        XCTAssertFalse(history.isRefreshing)
        let counts = await readings.counts
        XCTAssertEqual(counts, [0, 1])
    }

    func testStartupScanSurvivesCloseAndRapidReopenWithoutDuplicateFetch() async {
        let started = expectation(description: "Startup scan pauses while hidden")
        let gate = PanelScanGate()
        let readings = DashboardReadings()
        let history = HistoryStore(fetch: {
            let value = try await readings.history()
            await gate.pause(started: started)
            try Task.checkCancellation()
            return value
        })
        let view = HistoryPanelLifecycle.TrackingView(history: history)
        defer { Task { await gate.release() } }
        history.start()
        let start = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(start, .completed)
        guard start == .completed else { return }
        view.setVisible(true)
        view.setVisible(false)
        view.setVisible(true)
        view.setVisible(false)
        let joined = Task { await history.refresh() }
        await gate.release()
        await joined.value
        let counts = await readings.counts
        XCTAssertEqual(counts, [0, 1])
        XCTAssertEqual(history.summary?.tokens, 18_420)
        XCTAssertNil(history.error)
        XCTAssertFalse(history.isRefreshing)
    }
}

private actor PanelScanGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func pause(started: XCTestExpectation) async {
        guard !released else { return }
        await withCheckedContinuation {
            waiter = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
