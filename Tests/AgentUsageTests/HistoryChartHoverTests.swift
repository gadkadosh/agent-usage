import Foundation
import XCTest

@testable import AgentUsage

final class HistoryChartHoverTests: XCTestCase {
    func testHoverSelectsActualIntervalsIncludingGuttersAndZeroTokenBuckets() {
        let start = Date(timeIntervalSince1970: 0)
        // Include shortened hours and DST-length days rather than assuming fixed widths.
        let durations: [TimeInterval] = [1_800, 3_600, 23 * 3_600, 25 * 3_600]
        var cursor = start
        let buckets = durations.enumerated().map { index, duration in
            let end = cursor.addingTimeInterval(duration)
            defer { cursor = end }
            return HistoryBucket(start: cursor, end: end, tokens: Int64(index * 1_234))
        }
        let summary = PeriodSummary(tokens: 7_404, buckets: buckets)

        for bucket in buckets {
            XCTAssertEqual(summary.bucket(at: bucket.start), bucket)
            XCTAssertEqual(summary.bucket(at: bucket.barCenter), bucket)
            XCTAssertEqual(summary.bucket(at: bucket.barEnd), bucket)
            XCTAssertEqual(summary.bucket(at: bucket.end.addingTimeInterval(-0.001)), bucket)
        }
        XCTAssertEqual(summary.bucket(at: buckets[0].end)?.tokens, 1_234)
        XCTAssertEqual(summary.bucket(at: start)?.tokens, 0)
        XCTAssertNil(summary.bucket(at: start.addingTimeInterval(-0.001)))
        XCTAssertNil(summary.bucket(at: cursor))
    }

    func testHoverDoesNotSelectMissingIntervalsOrEmptySummaries() {
        let first = HistoryBucket(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_800),
            tokens: 123
        )
        let last = HistoryBucket(
            start: Date(timeIntervalSince1970: 3_600),
            end: Date(timeIntervalSince1970: 7_200),
            tokens: 456
        )
        let summary = PeriodSummary(tokens: 579, buckets: [first, last])
        XCTAssertNil(summary.bucket(at: first.end))
        XCTAssertNil(summary.bucket(at: Date(timeIntervalSince1970: 2_700)))
        XCTAssertEqual(summary.bucket(at: last.start), last)
        XCTAssertNil(PeriodSummary(tokens: 0, buckets: []).bucket(at: first.start))
    }
}
