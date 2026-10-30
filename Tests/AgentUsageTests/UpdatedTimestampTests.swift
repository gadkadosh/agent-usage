import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class UpdatedTimestampTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testTodaysReadingShowsTheTime() {
        let reading = date("2026-10-30T08:00:00Z")
        XCTAssertEqual(
            UpdatedTimestamp.timestamp(
                for: reading,
                relativeTo: date("2026-10-30T23:00:00Z"),
                calendar: calendar
            ),
            reading.formatted(date: .omitted, time: .shortened)
        )
    }

    func testYesterdayIsACalendarDayNotTheLast24Hours() {
        XCTAssertEqual(
            UpdatedTimestamp.timestamp(
                for: date("2026-10-29T23:59:00Z"),
                relativeTo: date("2026-10-30T00:01:00Z"),
                calendar: calendar
            ),
            "yesterday"
        )
        XCTAssertEqual(
            UpdatedTimestamp.timestamp(
                for: date("2026-10-29T00:01:00Z"),
                relativeTo: date("2026-10-30T23:59:00Z"),
                calendar: calendar
            ),
            "yesterday"
        )
    }

    func testOlderReadingShowsTheDateRatherThanAnAmbiguousTime() {
        let reading = date("2026-10-28T12:00:00Z")
        XCTAssertEqual(
            UpdatedTimestamp.timestamp(
                for: reading,
                relativeTo: date("2026-10-30T12:00:00Z"),
                calendar: calendar
            ),
            reading.formatted(.dateTime.month(.abbreviated).day())
        )
    }

    func testPreviousYearRemainsUnambiguous() {
        let reading = date("2025-10-28T12:00:00Z")
        XCTAssertEqual(
            UpdatedTimestamp.timestamp(
                for: reading,
                relativeTo: date("2026-10-30T12:00:00Z"),
                calendar: calendar
            ),
            reading.formatted(date: .abbreviated, time: .omitted)
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
