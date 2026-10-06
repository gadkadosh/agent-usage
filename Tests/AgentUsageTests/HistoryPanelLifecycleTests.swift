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

    func testRapidCloseReopenWaitsForCancelledScanThenFetches() async {
        let started = expectation(description: "First scan pauses")
        let resumed = expectation(description: "Reopen fetches")
        let gate = PanelScanGate()
        let readings = DashboardReadings()
        let history = HistoryStore(fetch: {
            let value = try await readings.history()
            let counts = await readings.counts
            if counts[1] == 1 { await gate.pause(started: started) } else { resumed.fulfill() }
            return value
        })
        let view = HistoryPanelLifecycle.TrackingView(history: history)
        defer {
            view.setVisible(false)
            Task { await gate.release() }
        }
        view.setVisible(true)
        let start = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(start, .completed)
        guard start == .completed else { return }
        view.setVisible(false)
        view.setVisible(true)
        XCTAssertNil(history.snapshot)
        await gate.release()
        let reopen = await XCTWaiter.fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(reopen, .completed)
        let counts = await readings.counts
        XCTAssertEqual(counts, [0, 2])
        XCTAssertNil(history.error)
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
