import AppKit
import SwiftUI
import XCTest

@testable import AgentUsage

/// Opt-in native captures, using only injected synthetic readings. No live stores or app startup.
@MainActor
final class DashboardRenderingTests: XCTestCase {
    func testRenderSyntheticDashboard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["AGENT_USAGE_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set AGENT_USAGE_RENDER_DIR to save synthetic native captures.")
        }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let scenarios: [(String, HistoryCoverage.State, HistoryPeriod, Bool)] = [
            ("ready-light-today", .ready, .today, false),
            ("ready-light-week", .ready, .week, false),
            ("ready-light-month", .ready, .month, false),
            ("ready-dark-week", .ready, .week, true),
            ("partial-light", .partial, .week, false),
            ("missing-light", .missing, .today, false),
            ("stale-light", .ready, .today, false),
            ("allowance-unavailable-light", .ready, .today, false),
            ("zero-light", .ready, .today, false),
            ("unsupported-light", .unsupported, .today, false),
            ("loading-light", .ready, .today, false),
        ]
        for (name, state, period, dark) in scenarios {
            let readings = DashboardReadings(
                failHistoryAfterFirst: name == "stale-light",
                snapshot: DashboardFixtures.history(state: state, zero: name == "zero-light")
            )
            let history = HistoryStore(fetch: { try await readings.history() })
            history.period = period
            if name != "loading-light" { await history.refresh() }
            if name == "stale-light" { await history.refresh() }
            let unavailable = name == "allowance-unavailable-light"
            let usage = UsageStore(
                fetch: {
                    if unavailable { throw SyntheticAllowanceError.unavailable }
                    return DashboardFixtures.limits
                },
                now: { DashboardFixtures.now }
            )
            await usage.refresh()
            let panel = DashboardPanel(
                usage: usage,
                history: history,
                referenceDate: DashboardFixtures.now
            )
            let countsBeforeRender = await readings.counts
            // Capture the production layout without window-triggered refreshes changing fixtures.
            try await capture(panel.content, named: name, in: destination, dark: dark)
            let countsAfterRender = await readings.counts
            XCTAssertEqual(countsAfterRender, countsBeforeRender)
        }
    }

    private func capture<V: View>(
        _ view: V,
        named name: String,
        in directory: URL,
        dark: Bool
    ) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView:
                view
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        // Give SwiftUI and Charts a turn to lay out and draw in a real native window.
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(data.count, 1_000)
    }

    private enum SyntheticAllowanceError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Synthetic allowance unavailable. Sign in again in pi."
        }
    }
}
