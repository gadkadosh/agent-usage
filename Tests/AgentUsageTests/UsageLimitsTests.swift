import Foundation
import XCTest

@testable import AgentUsage

final class UsageLimitsTests: XCTestCase {
    func testDecodesAndDisplaysBothWindows() throws {
        let json = """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 24, "reset_after_seconds": 3720 },
                "secondary_window": { "used_percent": 12.5, "reset_after_seconds": 90000 }
              }
            }
            """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let limits = try decoder.decode(UsageLimits.self, from: Data(json.utf8))

        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let allowance = limits.allowance(receivedAt: receivedAt)

        XCTAssertEqual(allowance.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(allowance.windows.map(\.title), ["5-hour window", "Weekly window"])
        XCTAssertEqual(allowance.windows.map(\.subtitle), ["", "7 days"])
        XCTAssertEqual(
            allowance.windows.map(\.resetsAt),
            [receivedAt.addingTimeInterval(3_720), receivedAt.addingTimeInterval(90_000)]
        )
        XCTAssertEqual(allowance.lowestRemainingFraction, 0.76)
    }

    func testRejectsMissingQuotaWindows() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(UsageLimits.self, from: Data("{}".utf8)))
    }
}
