import Foundation
import XCTest

@testable import AgentUsage

final class HistoryChartLabelsTests: XCTestCase {
    func testCaptionsIdentifyActualHourlyAndDailyBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-02T12:00:00Z")
        let expected: [(HistoryPeriod, [String])] = [
            (
                .today,
                [
                    "2026-10-02T00:00:00Z", "2026-10-02T08:00:00Z",
                    "2026-10-02T15:00:00Z", "2026-10-02T23:00:00Z",
                ]
            ),
            (
                .week,
                [
                    "2026-09-26T00:00:00Z", "2026-09-28T00:00:00Z",
                    "2026-09-30T00:00:00Z", "2026-10-02T00:00:00Z",
                ]
            ),
            (
                .month,
                [
                    "2026-09-03T00:00:00Z", "2026-09-13T00:00:00Z",
                    "2026-09-22T00:00:00Z", "2026-10-02T00:00:00Z",
                ]
            ),
        ]
        for (period, starts) in expected {
            let summary = PeriodSummary.aggregate([], period: period, now: now, calendar: calendar)
            let labels = summary.chartLabelBuckets
            XCTAssertEqual(labels.map(\.start), starts.map(date))
            XCTAssertTrue(labels.allSatisfy { summary.buckets.contains($0) })
            XCTAssertEqual(labels.first, summary.buckets.first)
            XCTAssertEqual(labels.last, summary.buckets.last)
        }
    }

    func testCaptionCentersExcludeTheBarGutterAndRespectActualIntervalLengths() {
        let start = date("2026-10-02T00:00:00Z")
        // Shortened hours and 23/25-hour days must not use a fixed clock offset.
        for duration: TimeInterval in [1_800, 3_600, 23 * 3_600, 25 * 3_600] {
            let bucket = HistoryBucket(start: start, end: start.addingTimeInterval(duration))
            XCTAssertEqual(bucket.barEnd.timeIntervalSince(start), duration * 0.9, accuracy: 0.001)
            XCTAssertEqual(
                bucket.barCenter.timeIntervalSince(start),
                duration * 0.45,
                accuracy: 0.001
            )
            XCTAssertEqual(
                bucket.barCenter.timeIntervalSince(start),
                bucket.barEnd.timeIntervalSince(bucket.barCenter),
                accuracy: 0.001
            )
        }
    }

    func testEmptyAndShortInjectedSummariesAreSafeAndKeepBucketIdentity() {
        let start = date("2026-10-02T00:00:00Z")
        for count in 0...4 {
            let buckets: [HistoryBucket] = (0..<count).map { index in
                let bucketStart = start.addingTimeInterval(Double(index) * 3_600)
                let bucketEnd = bucketStart.addingTimeInterval(3_600)
                return HistoryBucket(start: bucketStart, end: bucketEnd, tokens: Int64(index + 1))
            }
            let summary = PeriodSummary(
                tokens: buckets.reduce(0) { $0 + $1.tokens },
                buckets: buckets
            )
            XCTAssertEqual(summary.chartLabelBuckets, buckets)
        }
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
