import Foundation
import XCTest
@testable import AgentUsage

final class UsageSnapshotTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountdownUsesTimeSinceFetch() {
        let window = UsageLimits.Window(usedPercent: 24, resetAfterSeconds: 3_720)
        let snapshot = snapshot(window: window)

        XCTAssertEqual(snapshot.resetDescription(for: window, at: fetchedAt), "Resets in 1h 2m")
        XCTAssertEqual(snapshot.resetDescription(for: window, at: fetchedAt.addingTimeInterval(120)), "Resets in 1h 0m")
        XCTAssertEqual(snapshot.resetDescription(for: window, at: fetchedAt.addingTimeInterval(3_700)), "Resets in <1m")
        XCTAssertEqual(snapshot.resetDescription(for: window, at: fetchedAt.addingTimeInterval(3_720)), "Reset due")
        XCTAssertEqual(snapshot.resetDescription(for: window, at: fetchedAt.addingTimeInterval(4_000)), "Reset due")
    }

    func testWeeklyAndMinuteCountdowns() {
        let weekly = UsageLimits.Window(usedPercent: 12.5, resetAfterSeconds: 90_000)
        XCTAssertEqual(snapshot(window: weekly).resetDescription(for: weekly, at: fetchedAt), "Resets in 1d 1h")

        let short = UsageLimits.Window(usedPercent: 0, resetAfterSeconds: 120)
        XCTAssertEqual(snapshot(window: short).resetDescription(for: short, at: fetchedAt), "Resets in 2m")

        let expired = UsageLimits.Window(usedPercent: 100, resetAfterSeconds: -10)
        XCTAssertEqual(snapshot(window: expired).resetDescription(for: expired, at: fetchedAt), "Reset due")
    }

    func testMeterValuesAndWarningThreshold() {
        let window = UsageLimits.Window(usedPercent: 12.5, resetAfterSeconds: 60)
        XCTAssertEqual(window.remainingFraction, 0.875)
        XCTAssertEqual(window.remaining, "87.5%")
        XCTAssertFalse(window.isLowRemaining)
        XCTAssertFalse(UsageLimits.Window(usedPercent: 89.9, resetAfterSeconds: 0).isLowRemaining)
        let low = UsageLimits.Window(usedPercent: 90, resetAfterSeconds: 0)
        XCTAssertEqual(low.remainingFraction, 0.1)
        XCTAssertEqual(low.remaining, "10%")
        XCTAssertTrue(low.isLowRemaining)
    }

    func testOutOfRangeMeterValuesAreClamped() {
        let negative = UsageLimits.Window(usedPercent: -5, resetAfterSeconds: 0)
        XCTAssertEqual(negative.remainingFraction, 1)
        XCTAssertEqual(negative.remaining, "100%")
        XCTAssertFalse(negative.isLowRemaining)

        let overLimit = UsageLimits.Window(usedPercent: 105, resetAfterSeconds: 0)
        XCTAssertEqual(overLimit.remainingFraction, 0)
        XCTAssertEqual(overLimit.remaining, "0%")
        XCTAssertTrue(overLimit.isLowRemaining)

        let empty = UsageLimits.Window(usedPercent: 100, resetAfterSeconds: 0)
        XCTAssertEqual(empty.remainingFraction, 0)
        XCTAssertTrue(empty.isLowRemaining)

        let full = UsageLimits.Window(usedPercent: 0, resetAfterSeconds: 0)
        XCTAssertEqual(full.remainingFraction, 1)
        XCTAssertFalse(full.isLowRemaining)
    }

    private func snapshot(window: UsageLimits.Window) -> UsageSnapshot {
        UsageSnapshot(
            limits: UsageLimits(rateLimit: .init(primaryWindow: window, secondaryWindow: window)),
            fetchedAt: fetchedAt
        )
    }
}
