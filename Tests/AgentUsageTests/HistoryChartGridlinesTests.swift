import Foundation
import XCTest

@testable import AgentUsage

final class HistoryChartGridlinesTests: XCTestCase {
    func testWeekHasSeparatorsInEveryGapAndAtBothPlotEdges() {
        let summary = summary(.week)
        let start = summary.buckets.first!.start
        let expectedDays: [Double] = [0, 0.95, 1.95, 2.95, 3.95, 4.95, 5.95, 7]
        XCTAssertEqual(summary.chartGridlines.count, expectedDays.count)
        for (line, days) in zip(summary.chartGridlines, expectedDays) {
            XCTAssertEqual(line.timeIntervalSince(start), days * 86_400, accuracy: 0.001)
        }
    }

    func testDenseChartsUseTwoInteriorDividersInActualGaps() {
        let cases: [(HistoryPeriod, [Double])] = [
            (.today, [0, 7.95 * 3_600, 15.95 * 3_600, 24 * 3_600]),
            (.month, [0, 9.95 * 86_400, 19.95 * 86_400, 30 * 86_400]),
        ]
        for (period, offsets) in cases {
            let summary = summary(period)
            let start = summary.buckets.first!.start
            XCTAssertEqual(summary.chartGridlines.count, offsets.count)
            for (line, offset) in zip(summary.chartGridlines, offsets) {
                XCTAssertEqual(line.timeIntervalSince(start), offset, accuracy: 0.001)
            }
        }
    }

    func testSparseDividersStayInRealGapsOn23And25HourDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for timestamp in ["2026-03-08T16:00:00Z", "2026-11-01T17:00:00Z"] {
            let summary = PeriodSummary.aggregate(
                [],
                period: .today,
                now: ISO8601DateFormatter().date(from: timestamp)!,
                calendar: calendar
            )
            let lines = summary.chartGridlines
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines.first, summary.buckets.first!.start)
            XCTAssertEqual(lines.last, summary.buckets.last!.end)
            for line in lines.dropFirst().dropLast() {
                let gaps = zip(summary.buckets, summary.buckets.dropFirst())
                XCTAssertTrue(
                    gaps.contains { previous, next in
                        previous.barEnd < line && line < next.start
                    }
                )
            }
        }
    }

    func testEmptyAndSingleBucketSummariesHaveNoInteriorDividers() {
        XCTAssertEqual(PeriodSummary(tokens: 0, buckets: []).chartGridlines, [])
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(1_800)
        let bucket = HistoryBucket(start: start, end: end)
        XCTAssertEqual(PeriodSummary(tokens: 0, buckets: [bucket]).chartGridlines, [start, end])
    }

    private func summary(_ period: HistoryPeriod) -> PeriodSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return PeriodSummary.aggregate(
            [],
            period: period,
            now: ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!,
            calendar: calendar
        )
    }
}
