import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class PiHistoryAgeTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    // Fast-forward beyond the real filesystem ctime; tests never change the machine clock.
    private var future: Date {
        F.calendar.startOfDay(for: Date()).addingTimeInterval(40 * 86_400 + 12 * 3_600)
    }

    func testOldArchiveIsAnEmptyReadingWithoutParsingOrSpendingTheByteBudget() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [F.header(), F.message()])
        let before = try Data(contentsOf: file)
        let source = PiHistorySource(
            root: fixture.root,
            limits: .init(fileBytes: 1, refreshBytes: 1)
        )

        let snapshot = try await source.refresh(now: future, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertTrue(snapshot.coverage.hasReadings)
        XCTAssertEqual(snapshot.coverage.filesRead, 0)
        XCTAssertEqual(snapshot.coverage.filesSkipped, 1)
        XCTAssertEqual(snapshot.coverage.issues, [])
        XCTAssertNil(snapshot.coverage.warning)
        XCTAssertFalse(snapshot.hasMoreFiles)
        for period in HistoryPeriod.allCases {
            XCTAssertEqual(snapshot.summaries[period]?.tokens, 0)
            XCTAssertTrue(snapshot.summaries[period]!.buckets.allSatisfy { $0.tokens == 0 })
        }
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)

        try FileManager.default.removeItem(at: file)
        let deleted = try await source.refresh(now: future, calendar: F.calendar)
        XCTAssertEqual(deleted.coverage.state, .missing)
        XCTAssertFalse(deleted.coverage.hasReadings)
        XCTAssertEqual(deleted.coverage.filesSkipped, 0)
    }

    func testOldFilesLeaveTheReadBudgetAvailableForRecentUsage() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let now = future
        try fixture.write(
            "old.jsonl",
            lines: [
                F.header(),
                F.message(extra: ",\"content\":\"\(String(repeating: "x", count: 4_096))\""),
            ]
        )
        let recent = try fixture.write(
            "recent.jsonl",
            lines: [
                F.header(), F.message(time: Int64(now.timeIntervalSince1970 * 1_000)),
            ]
        )
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recent.path)
        let size = try Data(contentsOf: recent).count
        let source = PiHistorySource(
            root: fixture.root,
            limits: .init(fileBytes: size, refreshBytes: size)
        )

        let snapshot = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertEqual(snapshot.coverage.filesRead, 1)
        XCTAssertEqual(snapshot.coverage.filesSkipped, 1)
        XCTAssertEqual(snapshot.coverage.issues, [])
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertFalse(snapshot.hasMoreFiles)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 1)
    }

    func testOldArchiveDoesNotHideOtherCoverageGaps() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), F.message()])
        try fixture.write("unknown.txt", lines: ["not a session"])
        let source = PiHistorySource(root: fixture.root)

        let snapshot = try await source.refresh(now: future, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .partial)
        XCTAssertTrue(snapshot.coverage.hasReadings)
        XCTAssertEqual(snapshot.coverage.filesRead, 0)
        XCTAssertEqual(snapshot.coverage.filesSkipped, 1)
        XCTAssertEqual(snapshot.summaries[.month]?.tokens, 0)
        XCTAssertEqual(snapshot.coverage.issues, [.unsupportedRecord])
        XCTAssertEqual(snapshot.coverage.warning, "Partial history. Totals may be incomplete.")
    }

    func testRecentCtimeKeepsAFileWhoseMtimeWasBackdated() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let now = Date()
        let since = HistoryPeriod.month.start(at: now, calendar: F.calendar)
        let file = try fixture.write(lines: [
            F.header(), F.message(time: Int64(now.timeIntervalSince1970 * 1_000)),
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: since.addingTimeInterval(-86_400)],
            ofItemAtPath: file.path
        )
        let source = PiHistorySource(root: fixture.root)

        let snapshot = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertEqual(snapshot.coverage.filesRead, 1)
        XCTAssertEqual(snapshot.coverage.filesSkipped, 0)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 1)
    }

    func testCalendarCutoffIsInclusiveAndUsesSubsecondModificationTimes() async throws {
        // A non-UTC calendar must use its local midnight, not a rolling 30 * 24 hours.
        var calendar = F.calendar
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = future
        let since = HistoryPeriod.month.start(at: now, calendar: calendar)
        for offset in [-0.001, 0, 0.001, 3_600] {
            let fixture = try PiHistoryFixtureRoot()
            defer { fixture.remove() }
            let file = try fixture.write(lines: [
                F.header(), F.message(time: Int64(since.timeIntervalSince1970 * 1_000)),
            ])
            try FileManager.default.setAttributes(
                [.modificationDate: since.addingTimeInterval(offset)],
                ofItemAtPath: file.path
            )
            let source = PiHistorySource(root: fixture.root)
            let snapshot = try await source.refresh(now: now, calendar: calendar)
            let included = offset >= 0
            XCTAssertEqual(snapshot.summaries[.month]?.tokens, included ? 190 : 0)
            XCTAssertEqual(snapshot.coverage.filesRead, included ? 1 : 0)
            XCTAssertEqual(snapshot.coverage.filesSkipped, included ? 0 : 1)
            let parsed = await source.filesParsed
            XCTAssertEqual(parsed, included ? 1 : 0)
        }
    }

    func testResumingAnExcludedSessionMakesItEligibleOnTheNextRefresh() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [F.header(), F.message()])
        let source = PiHistorySource(root: fixture.root)
        let now = future
        let old = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(old.coverage.filesSkipped, 1)
        XCTAssertEqual(old.summaries[.today]?.tokens, 0)

        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(
            contentsOf: Data(
                (F.message(
                    id: "resumed",
                    time: Int64(now.timeIntervalSince1970 * 1_000)
                ) + "\n").utf8
            )
        )
        try writer.close()
        // Simulate the write's mtime at the fast-forwarded test clock.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let resumed = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(resumed.summaries[.today]?.tokens, 190)
        XCTAssertEqual(resumed.coverage.filesRead, 1)
        XCTAssertEqual(resumed.coverage.filesSkipped, 0)
        XCTAssertEqual(resumed.coverage.issues, [])
        let warm = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(warm.summaries, resumed.summaries)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 1)
    }

    func testCachedSessionAgesOutAndBecomesReadableAgainWhenTheClockMovesBack() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(lines: [
            F.header(), F.message(time: Int64(now.timeIntervalSince1970 * 1_000)),
        ])
        let source = PiHistorySource(root: fixture.root)
        let initial = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(initial.summaries[.today]?.tokens, 190)

        let aged = try await source.refresh(now: future, calendar: F.calendar)
        XCTAssertEqual(aged.summaries[.month]?.tokens, 0)
        XCTAssertEqual(aged.coverage.filesRead, 0)
        XCTAssertEqual(aged.coverage.filesSkipped, 1)
        var parsed = await source.filesParsed
        XCTAssertEqual(parsed, 1)

        let restored = try await source.refresh(now: now, calendar: F.calendar)
        XCTAssertEqual(restored.summaries, initial.summaries)
        XCTAssertEqual(restored.coverage.filesRead, 1)
        XCTAssertEqual(restored.coverage.filesSkipped, 0)
        parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)
    }
}
