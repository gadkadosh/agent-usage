import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryLiveTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testLiveStoreReadsPeriodsFromInjectedRootWithoutAllowanceOrInputWrites() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let now = F.now
        let calendar = F.calendar
        let file = try fixture.write(
            lines: [F.header()]
                + [0, 3, 20].map { days in
                    let date = calendar.date(byAdding: .day, value: -days, to: now)!
                    return message(id: "day-\(days)", at: date)
                })
        let before = try Data(contentsOf: file)
        let history = liveStore(root: fixture.root)
        let allowance = UsageStore(fetch: { throw URLError(.notConnectedToInternet) })
        await allowance.refresh()
        await history.refresh()

        XCTAssertNotNil(allowance.error)
        XCTAssertNil(allowance.snapshot)
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.coverage.state, .ready)
        XCTAssertEqual(history.snapshot?.coverage.filesRead, 1)
        XCTAssertEqual(history.snapshot?.summaries[.today]?.tokens, 190)
        XCTAssertEqual(history.snapshot?.summaries[.week]?.tokens, 380)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 570)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(HistoryStore.liveRefreshInterval, .seconds(60))
    }

    func testLiveStoreKeepsFileIndexAcrossRefreshesAndRecoversUnreadableFile() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let now = F.now
        let file = try fixture.write(lines: [F.header(), message(at: now)])
        let history = liveStore(root: fixture.root)
        await history.refresh()
        try fixture.write(lines: [F.header(), message(at: now), message(id: "new", at: now)])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path))
        await history.refresh()
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 190)
        XCTAssertEqual(history.snapshot?.coverage.state, .partial)
        XCTAssertTrue(history.snapshot!.coverage.issues.contains(.staleFile))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await history.refresh()
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 380)
        XCTAssertEqual(history.snapshot?.coverage.state, .ready)
    }

    func testLiveStorePreservesLastSnapshotWhenRootFailsAndRecovers() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), message()])
        let history = liveStore(root: fixture.root)
        await history.refresh()
        let previous = try XCTUnwrap(history.snapshot)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: fixture.root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: fixture.root.path))
        await history.refresh()
        XCTAssertEqual(history.error, HistoryReadError.unavailable.localizedDescription)
        XCTAssertEqual(history.snapshot?.fetchedAt, previous.fetchedAt)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 190)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        await history.refresh()
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.coverage.state, .ready)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 190)
    }

    func testLiveStoreMissingRootIsNotCreatedOrReportedAsObservedZero() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let history = liveStore(root: missing)
        await history.refresh()
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.coverage.state, .missing)
        XCTAssertEqual(history.snapshot?.coverage.hasReadings, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func liveStore(root: URL) -> HistoryStore {
        HistoryStore.live(root: root, now: { F.now }, calendar: F.calendar)
    }

    private func message(id: String = "first", at date: Date = F.now) -> String {
        F.message(id: id, time: Int64(date.timeIntervalSince1970 * 1_000))
    }
}
