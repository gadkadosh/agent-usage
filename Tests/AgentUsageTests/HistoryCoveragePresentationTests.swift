import XCTest

@testable import AgentUsage

final class HistoryCoveragePresentationTests: XCTestCase {
    func testHealthyHistoryHasNoWarning() {
        XCTAssertNil(HistoryCoverage(state: .ready, hasReadings: true, issues: []).warning)
    }

    func testEmptyStatesDoNotRepeatTheirExplanationInTheFooter() {
        for state in [HistoryCoverage.State.missing, .unsupported, .unavailable, .partial] {
            XCTAssertNil(
                HistoryCoverage(state: state, hasReadings: false, issues: [.unreadableFile]).warning
            )
        }
    }

    func testExclusionsShareOneWarningInsteadOfListingParserDetails() {
        for issue in HistoryIssue.allCases where issue != .staleFile && issue != .toolAggregate {
            XCTAssertEqual(
                HistoryCoverage(state: .partial, hasReadings: true, issues: [issue]).warning,
                "Partial history. Totals may be incomplete."
            )
        }
        XCTAssertEqual(
            HistoryCoverage(state: .partial, hasReadings: true, issues: []).warning,
            "Partial history. Totals may be incomplete."
        )
    }

    func testStaleAndOverlappingUsageRemainVisibleAlongsideExclusions() {
        XCTAssertEqual(
            HistoryCoverage(
                state: .partial,
                hasReadings: true,
                issues: Set(HistoryIssue.allCases)
            ).warning,
            "Partial history. Totals may be incomplete. Includes older readings. Tool usage may be counted twice."
        )
    }

    func testToolOverlapIsNotPresentedAsMissingUsage() {
        XCTAssertEqual(
            HistoryCoverage(state: .ready, hasReadings: true, issues: [.toolAggregate]).warning,
            "Tool usage may be counted twice."
        )
    }
}
