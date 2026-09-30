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

        XCTAssertEqual(limits.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(limits.details, "5h: 76%  7d: 87.5% | 5h: 1h2m  7d: 1d1h")
    }

    func testRejectsMissingQuotaWindows() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(UsageLimits.self, from: Data("{}".utf8)))
    }
}
