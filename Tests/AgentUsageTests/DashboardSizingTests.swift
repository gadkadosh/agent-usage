import AppKit
import SwiftUI
import XCTest

@testable import AgentUsage

@MainActor
final class DashboardSizingTests: XCTestCase {
    func testPanelRemainsBoundedAndScrollableAfterRefresh() async throws {
        let readings = SizingReadings()
        let usage = UsageStore(
            fetch: { try await readings.allowance() }, now: { DashboardFixtures.now })
        let history = HistoryStore(fetch: { DashboardFixtures.history() })
        await usage.refresh()
        await history.refresh()
        let host = NSHostingView(
            rootView: DashboardPanel(
                usage: usage, history: history, referenceDate: DashboardFixtures.now))
        let window = makeWindow(host)
        defer { window.close() }

        let ready = try await fittedSize(host)
        XCTAssertEqual(ready.width, 360, accuracy: 1)
        let cap = max(240, min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
        XCTAssertGreaterThan(ready.height, 0)
        XCTAssertLessThanOrEqual(ready.height, cap + 1)

        await readings.setError("Synthetic allowance unavailable. Sign in again in pi.")
        await usage.refresh()
        let warning = try await fittedSize(host)
        XCTAssertEqual(warning.width, 360, accuracy: 1)
        XCTAssertGreaterThan(warning.height, 0)
        XCTAssertLessThanOrEqual(warning.height, cap + 1)

        await readings.setError(String(repeating: "Synthetic allowance unavailable. ", count: 80))
        await usage.refresh()
        let overflowing = try await fittedSize(host)
        XCTAssertEqual(overflowing.height, cap, accuracy: 1)
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(
            to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Overflow must remain scrollable.")

        await readings.setError(nil)
        await usage.refresh()
        let recovered = try await fittedSize(host)
        XCTAssertEqual(recovered.height, ready.height, accuracy: 1)
    }

    func testHistoryLayoutsRemainBoundedAndDoNotRefetch() async throws {
        let usage = UsageStore(fetch: { DashboardFixtures.limits }, now: { DashboardFixtures.now })
        await usage.refresh()
        let cap = max(240, min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
        for state in [HistoryCoverage.State.ready, .partial, .missing] {
            let readings = DashboardReadings(snapshot: DashboardFixtures.history(state: state))
            let history = HistoryStore(fetch: { try await readings.history() })
            await history.refresh()
            let host = NSHostingView(
                rootView: DashboardPanel(
                    usage: usage, history: history, referenceDate: DashboardFixtures.now
                ).content)
            let window = makeWindow(host)
            let size = try await fittedSize(host)
            XCTAssertEqual(size.width, 360, accuracy: 1)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.height, cap + 1)
            window.close()
            let counts = await readings.counts
            XCTAssertEqual(counts, [0, 1])
        }
    }

    private func makeWindow<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        return window
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

    func setError(_ error: String?) { self.error = error }

    func allowance() throws -> UsageLimits {
        if let error { throw Failure(message: error) }
        return DashboardFixtures.limits
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
