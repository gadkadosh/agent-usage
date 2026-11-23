import Foundation
import XCTest

@testable import AgentUsage

final class UsageLimitsTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testDecodesAndDisplaysPaidPlanWindows() throws {
        let json = """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 24, "limit_window_seconds": 18000, "reset_after_seconds": 3720
                },
                "secondary_window": {
                  "used_percent": 12.5, "limit_window_seconds": 604800, "reset_after_seconds": 90000
                }
              }
            }
            """
        let allowance = try UsageLimits.decode(Data(json.utf8)).allowance(receivedAt: receivedAt)

        XCTAssertEqual(allowance.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(allowance.windows.map(\.title), ["5-hour window", "Weekly window"])
        XCTAssertEqual(allowance.windows.map(\.subtitle), ["", "7 days"])
        XCTAssertEqual(
            allowance.windows.map(\.resetsAt),
            [receivedAt.addingTimeInterval(3_720), receivedAt.addingTimeInterval(90_000)]
        )
        XCTAssertEqual(allowance.lowestRemainingFraction, 0.76)
    }

    /// Shape returned for a free-plan account on 2026-11-23.
    func testDisplaysFreePlanSingleMonthlyWindow() throws {
        let json = """
            {
              "plan_type": "free",
              "rate_limit": {
                "allowed": false, "limit_reached": true,
                "primary_window": {
                  "used_percent": 100, "limit_window_seconds": 2592000,
                  "reset_after_seconds": 2268693, "reset_at": 1797701814
                },
                "secondary_window": null
              },
              "additional_rate_limits": null
            }
            """
        let allowance = try UsageLimits.decode(Data(json.utf8)).allowance(receivedAt: receivedAt)

        XCTAssertEqual(allowance.summary, "30d: 0%")
        XCTAssertEqual(allowance.windows.map(\.title), ["30-day window"])
        XCTAssertEqual(allowance.windows[0].resetsAt, receivedAt.addingTimeInterval(2_268_693))
    }

    func testRejectsMissingQuotaWindows() {
        XCTAssertThrowsError(try UsageLimits.decode(Data("{}".utf8)))
    }
}
