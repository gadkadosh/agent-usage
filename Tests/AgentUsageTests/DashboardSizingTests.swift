import AppKit
import SwiftUI
import XCTest

@testable import AgentUsage

@MainActor
final class DashboardSizingTests: XCTestCase {
    func testScreenBudgetHasNoArbitraryCeilingOrMinimum() {
        XCTAssertEqual(DashboardWindowSize.maximumHeight(for: 1_000), 960)
        XCTAssertEqual(DashboardWindowSize.maximumHeight(for: 500), 460)
        XCTAssertEqual(DashboardWindowSize.maximumHeight(for: 200), 160)
        XCTAssertEqual(DashboardWindowSize.maximumHeight(for: 30), 1)
    }

    func testOverflowUsesTheHostingWindowsScreenBudget() async throws {
        let readings = SizingReadings()
        await readings.setError(String(repeating: "Synthetic allowance unavailable. ", count: 200))
        let usage = UsageStore(fetch: { try await readings.allowance() })
        let history = HistoryStore(fetch: { DashboardFixtures.history() })
        await usage.refresh()
        await history.refresh()
        let host = NSHostingView(rootView: DashboardPanel(usage: usage, history: history))
        let window = makeWindow(host)
        defer { window.close() }
        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
            NotificationCenter.default.post(
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            let size = try await fittedSize(host)
            let actualScreen = try XCTUnwrap(window.screen)
            XCTAssertEqual(actualScreen, screen)
            XCTAssertEqual(size.height, screen.visibleFrame.height - 40, accuracy: 1)
            XCTAssertEqual(window.frame.height, size.height, accuracy: 1)
            let scroll = try XCTUnwrap(scrollView(in: host))
            XCTAssertGreaterThan(
                try XCTUnwrap(scroll.documentView).bounds.height,
                scroll.contentView.bounds.height
            )
        }
    }

    func testPanelFitsContentAndResizesAfterRefresh() async throws {
        let readings = SizingReadings()
        let usage = UsageStore(
            fetch: { try await readings.allowance() },
            now: { DashboardFixtures.now }
        )
        let history = HistoryStore(fetch: { DashboardFixtures.history() })
        await usage.refresh()
        await history.refresh()
        let host = NSHostingView(
            rootView: DashboardPanel(
                usage: usage,
                history: history,
                referenceDate: DashboardFixtures.now
            )
        )
        let window = makeWindow(host)
        defer { window.close() }
        let top = window.frame.maxY

        let ready = try await fittedSize(host)
        assertWindow(window, fits: ready, top: top)
        XCTAssertEqual(ready.width, 360, accuracy: 1)
        let cap = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        XCTAssertGreaterThan(ready.height, 0)
        XCTAssertLessThanOrEqual(ready.height, cap + 1)

        await readings.setError("Synthetic allowance unavailable. Sign in again in pi.")
        await usage.refresh()
        let warning = try await fittedSize(host)
        assertWindow(window, fits: warning, top: top)
        XCTAssertEqual(warning.width, 360, accuracy: 1)
        XCTAssertGreaterThan(warning.height, 0)
        XCTAssertLessThanOrEqual(warning.height, cap + 1)
        XCTAssertGreaterThan(warning.height, ready.height)

        await readings.setError(String(repeating: "Synthetic allowance unavailable. ", count: 80))
        await usage.refresh()
        let overflowing = try await fittedSize(host)
        assertWindow(window, fits: overflowing, top: top)
        XCTAssertEqual(overflowing.height, cap, accuracy: 1)
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(
            to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height)
        )
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Overflow must remain scrollable.")

        await readings.setError(nil)
        await usage.refresh()
        let recovered = try await fittedSize(host)
        assertWindow(window, fits: recovered, top: top)
        XCTAssertEqual(recovered.height, ready.height, accuracy: 1)
    }

    func testRetainedWindowTracksHistoryWithoutLayoutFetchesAndKeepsTopEdge() async throws {
        let readings = SizingReadings()
        await readings.setHistoryState(.partial)
        let usage = UsageStore(fetch: { DashboardFixtures.limits }, now: { DashboardFixtures.now })
        let history = HistoryStore(fetch: { await readings.history() })
        await usage.refresh()
        await history.refresh()
        let host = NSHostingView(
            rootView: DashboardPanel(
                usage: usage,
                history: history,
                referenceDate: DashboardFixtures.now
            )
        )
        let window = makeWindow(host)
        defer { window.close() }
        let top = window.frame.maxY
        let partial = try await fittedSize(host)
        assertWindow(window, fits: partial, top: top)

        var heights: [CGFloat] = []
        for state in [HistoryCoverage.State.ready, .missing, .partial, .ready] {
            await readings.setHistoryState(state)
            await history.refresh()
            let readsBeforeLayout = await readings.historyFetchCount
            let size = try await fittedSize(host)
            assertWindow(window, fits: size, top: top)
            let readsAfterLayout = await readings.historyFetchCount
            XCTAssertEqual(readsAfterLayout, readsBeforeLayout, "Layout must not refetch history.")
            heights.append(size.height)
        }
        XCTAssertLessThan(heights[0], partial.height)
        XCTAssertLessThan(heights[1], heights[0])
        XCTAssertEqual(heights[2], partial.height, accuracy: 1)
        XCTAssertEqual(heights[3], heights[0], accuracy: 1)
    }

    func testHistoryCatchUpDoesNotChangePanelHeight() async throws {
        let ready = DashboardFixtures.history()
        let updates = AsyncStream<HistorySnapshot>.makeStream()
        defer { updates.continuation.finish() }
        let history = HistoryStore(fetchUpdates: { publish in
            for await snapshot in updates.stream {
                await publish(snapshot)
            }
            return ready
        })
        let usage = UsageStore(fetch: { DashboardFixtures.limits }, now: { DashboardFixtures.now })
        await usage.refresh()
        history.start()
        updates.continuation.yield(ready)
        let host = NSHostingView(
            rootView: DashboardPanel(
                usage: usage,
                history: history,
                referenceDate: DashboardFixtures.now
            ).content
        )
        let window = makeWindow(host)
        defer { window.close() }
        let initial = try await fittedSize(host)
        XCTAssertNotNil(history.snapshot)
        XCTAssertTrue(history.isRefreshing)

        var pending = ready
        pending.hasMore = true
        updates.continuation.yield(pending)
        let catchingUp = try await fittedSize(host)
        XCTAssertEqual(history.snapshot?.hasMore, true)
        XCTAssertTrue(history.isRefreshing)
        XCTAssertEqual(catchingUp.height, initial.height, accuracy: 1)

        updates.continuation.finish()
        await history.refresh()
        let finished = try await fittedSize(host)
        XCTAssertFalse(history.isRefreshing)
        XCTAssertEqual(finished.height, initial.height, accuracy: 1)
    }

    func testInitialContentLayoutDoesNotFetchHistory() async throws {
        let usage = UsageStore(fetch: { DashboardFixtures.limits }, now: { DashboardFixtures.now })
        await usage.refresh()
        for state in [HistoryCoverage.State.ready, .partial, .missing] {
            let readings = DashboardReadings(snapshot: DashboardFixtures.history(state: state))
            let history = HistoryStore(fetch: { try await readings.history() })
            await history.refresh()
            // Exclude the intentional native-window visibility refresh from this layout check.
            let host = NSHostingView(
                rootView: DashboardPanel(
                    usage: usage,
                    history: history,
                    referenceDate: DashboardFixtures.now
                ).content
            )
            let window = makeWindow(host)
            defer { window.close() }
            _ = try await fittedSize(host)
            let counts = await readings.counts
            XCTAssertEqual(counts, [0, 1], "Initial layout must not refetch history (\(state)).")
        }
    }

    private func makeWindow<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Test the dashboard's native resize boundary, not hosting min/max constraints.
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    private func assertWindow(
        _ window: NSWindow,
        fits size: NSSize,
        top: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(actual.width, size.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, size.height, accuracy: 1, file: file, line: line)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1, file: file, line: line)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func fittedSize<V: View>(_ host: NSHostingView<V>) async throws -> NSSize {
        // Allow SwiftUI's measured content height to update the native ideal size.
        host.layoutSubtreeIfNeeded()
        host.display()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}

private actor SizingReadings {
    var error: String?
    var historyState = HistoryCoverage.State.ready
    private(set) var historyFetchCount = 0

    func setError(_ error: String?) { self.error = error }
    func setHistoryState(_ state: HistoryCoverage.State) { historyState = state }
    func history() -> HistorySnapshot {
        historyFetchCount += 1
        return DashboardFixtures.history(state: historyState)
    }

    func allowance() throws -> UsageLimits {
        if let error { throw Failure(message: error) }
        return DashboardFixtures.limits
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
