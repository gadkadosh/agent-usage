import Foundation
import XCTest

@testable import AgentUsage

final class HistorySummaryTests: XCTestCase {
    func testCalendarRangesAndOperationTimestampsNotSessionLifetime() {
        let calendar = calendar("UTC")
        let now = date("2026-10-02T12:00:00Z")
        let records = [
            observation("today", "2026-10-02T00:00:00Z", 10),
            observation("now", "2026-10-02T12:00:00Z", 20),
            observation("yesterday", "2026-10-01T23:59:59Z", 30),
            observation("week-start", "2026-09-26T00:00:00Z", 40),
            observation("before-week", "2026-09-25T23:59:59Z", 50),
            observation("month-start", "2026-09-03T00:00:00Z", 60),
            observation("before-month", "2026-09-02T23:59:59Z", 70),
            observation("future", "2026-10-02T12:00:01Z", 80),
        ]
        for (period, total, count) in [
            (HistoryPeriod.today, Int64(30), 24), (.week, 100, 7), (.month, 210, 30),
        ] {
            let summary = PeriodSummary.aggregate(
                records, period: period, now: now, calendar: calendar)
            XCTAssertEqual(summary.tokens, total)
            XCTAssertEqual(summary.buckets.count, count)
            XCTAssertEqual(summary.buckets.reduce(0) { $0 + $1.tokens }, total)
        }
    }

    func testCopiesCountOnceButSameTokenCountDoesNotMeanSameOperation() {
        let record = observation("original", "2026-10-02T01:00:00Z", 100)
        let separate = observation("different", "2026-10-02T01:00:00Z", 100)
        let summary = PeriodSummary.aggregate(
            [record, record, separate], period: .today, now: date("2026-10-02T12:00:00Z"),
            calendar: calendar("UTC")
        )
        XCTAssertEqual(summary.tokens, 200)
        XCTAssertEqual(summary.buckets[1].tokens, 200)
        XCTAssertEqual(summary.buckets.filter { $0.tokens == 0 }.count, 23)
    }

    func testDSTTodayHas23Or25HoursAndRepeatedHourStaysSeparate() {
        let calendar = calendar("America/New_York")
        let spring = PeriodSummary.aggregate(
            [], period: .today, now: date("2026-03-09T03:59:59Z"), calendar: calendar
        )
        XCTAssertEqual(spring.buckets.count, 23)
        let fall = PeriodSummary.aggregate(
            [
                observation("first1am", "2026-11-01T05:30:00Z", 10),
                observation("second1am", "2026-11-01T06:30:00Z", 20),
            ],
            period: .today, now: date("2026-11-02T04:59:59Z"), calendar: calendar
        )
        XCTAssertEqual(fall.buckets.count, 25)
        XCTAssertEqual(fall.tokens, 30)
        XCTAssertEqual(fall.buckets[1].tokens, 10)
        XCTAssertEqual(fall.buckets[2].tokens, 20)
        let week = PeriodSummary.aggregate(
            [], period: .week, now: date("2026-11-02T04:59:59Z"), calendar: calendar)
        XCTAssertEqual(week.buckets.count, 7)
        XCTAssertEqual(
            week.buckets.last!.end.timeIntervalSince(week.buckets.last!.start), 25 * 3_600)
    }

    func testHalfHourDSTShiftsStillCountEveryTimestampExactlyOnce() {
        let calendar = calendar("Australia/Lord_Howe")
        for day in ["2026-10-04T12:00:00Z", "2026-04-05T12:00:00Z"] {
            let now = date(day)
            let interval = calendar.dateInterval(of: .day, for: now)!
            var records: [UsageObservation] = []
            var cursor = interval.start
            while cursor <= now {
                records.append(
                    UsageObservation(operationID: "\(cursor)", timestamp: cursor, tokens: 10))
                cursor = cursor.addingTimeInterval(900)
            }
            let summary = PeriodSummary.aggregate(
                records, period: .today, now: now, calendar: calendar)
            XCTAssertEqual(summary.tokens, Int64(records.count * 10))
            XCTAssertEqual(summary.buckets.last?.end, interval.end)
            for pair in zip(summary.buckets, summary.buckets.dropFirst()) {
                XCTAssertEqual(pair.0.end, pair.1.start)
            }
        }
    }

    func testMidnightDSTUsesActualCalendarDayBoundaries() {
        let calendar = calendar("America/Santiago")
        let now = date("2026-09-12T20:00:00Z")
        let summary = PeriodSummary.aggregate([], period: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.buckets.count, 7)
        XCTAssertEqual(calendar.component(.hour, from: summary.buckets[0].start), 1)
        XCTAssertEqual(calendar.component(.hour, from: summary.buckets[1].start), 0)
        XCTAssertEqual(
            summary.buckets[0].end.timeIntervalSince(summary.buckets[0].start), 23 * 3_600)
    }

    func testMidnightAndTimeZoneChangesUseLocalCalendar() {
        let now = date("2026-10-02T00:30:00Z")
        let record = observation("record", "2026-10-01T23:00:00Z", 10)
        XCTAssertEqual(
            PeriodSummary.aggregate([record], period: .today, now: now, calendar: calendar("UTC"))
                .tokens, 0)
        XCTAssertEqual(
            PeriodSummary.aggregate(
                [record], period: .today, now: now, calendar: calendar("America/Los_Angeles")
            ).tokens, 10
        )
    }

    private func observation(_ id: String, _ timestamp: String, _ tokens: Int64) -> UsageObservation
    {
        UsageObservation(operationID: id, timestamp: date(timestamp), tokens: tokens)
    }

    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
}
