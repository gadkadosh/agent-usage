import Foundation
import XCTest

@testable import AgentUsage

final class AllowanceWindowTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountdownUsesTimeUntilReset() {
        let window = makeWindow(used: 24, resetIn: 3_720)

        XCTAssertEqual(window.resetDescription(at: fetchedAt), "Resets in 1h 2m")
        XCTAssertEqual(
            window.resetDescription(at: fetchedAt.addingTimeInterval(120)),
            "Resets in 1h 0m"
        )
        XCTAssertEqual(
            window.resetDescription(at: fetchedAt.addingTimeInterval(3_700)),
            "Resets in <1m"
        )
        XCTAssertEqual(
            window.resetDescription(at: fetchedAt.addingTimeInterval(3_720)),
            "Reset due"
        )
        XCTAssertEqual(
            window.resetDescription(at: fetchedAt.addingTimeInterval(4_000)),
            "Reset due"
        )
    }

    func testWeeklyAndMinuteCountdowns() {
        let weekly = makeWindow(used: 12.5, resetIn: 90_000)
        XCTAssertEqual(
            weekly.resetDescription(at: fetchedAt),
            "Resets in 1d 1h"
        )

        let short = makeWindow(used: 0, resetIn: 120)
        XCTAssertEqual(
            short.resetDescription(at: fetchedAt),
            "Resets in 2m"
        )

        let expired = makeWindow(used: 100, resetIn: -10)
        XCTAssertEqual(
            expired.resetDescription(at: fetchedAt),
            "Reset due"
        )
    }

    func testMeterValuesRepresentRemainingAllowance() {
        let window = makeWindow(used: 12.5, resetIn: 60)
        XCTAssertEqual(window.remainingFraction, 0.875)
        XCTAssertEqual(window.remaining, "87.5%")
        let low = makeWindow(used: 90, resetIn: 0)
        XCTAssertEqual(low.remainingFraction, 0.1)
        XCTAssertEqual(low.remaining, "10%")
    }

    func testMeterOpacityIncreasesGraduallyWithRemaining() {
        let cases: [(Double, Double)] = [
            (0, 0.65), (10, 0.685), (25, 0.7375),
            (50, 0.825), (75, 0.9125), (100, 1),
        ]
        for (remaining, opacity) in cases {
            let window = makeWindow(used: 100 - remaining, resetIn: 0)
            XCTAssertEqual(window.meterOpacity, opacity, accuracy: 0.000001)
        }
    }

    func testOutOfRangeMeterValuesAreClamped() {
        let negative = makeWindow(used: -5, resetIn: 0)
        XCTAssertEqual(negative.remainingFraction, 1)
        XCTAssertEqual(negative.remaining, "100%")
        XCTAssertEqual(negative.meterOpacity, 1)

        let overLimit = makeWindow(used: 105, resetIn: 0)
        XCTAssertEqual(overLimit.remainingFraction, 0)
        XCTAssertEqual(overLimit.remaining, "0%")
        XCTAssertEqual(overLimit.meterOpacity, 0.65)

        let empty = makeWindow(used: 100, resetIn: 0)
        XCTAssertEqual(empty.remainingFraction, 0)
        XCTAssertEqual(empty.meterOpacity, 0.65)

        let full = makeWindow(used: 0, resetIn: 0)
        XCTAssertEqual(full.remainingFraction, 1)
        XCTAssertEqual(full.meterOpacity, 1)
    }

    private func makeWindow(used: Double, resetIn seconds: TimeInterval) -> AllowanceWindow {
        AllowanceWindow(
            label: "5h",
            title: "5-hour window",
            subtitle: "",
            usedPercent: used,
            resetsAt: fetchedAt.addingTimeInterval(seconds)
        )
    }
}
