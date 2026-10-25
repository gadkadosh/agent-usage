import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryLiveTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testExplicitAdaptersReadOnlyTheirSyntheticHistories() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("pi/session.jsonl", lines: [F.header(), F.message()])
        try fixture.write(
            "codex/sessions/rollout.jsonl",
            lines: [CodexHistoryFixtures.header(), CodexHistoryFixtures.durable()]
        )
        let pi = PiHistorySource(root: fixture.root.appendingPathComponent("pi"))
        let codex = CodexHistorySource(home: fixture.root.appendingPathComponent("codex"))
        for (adapters, ids, total) in [
            ([pi] as [any HistoryAdapter], [HistoryAgentID.pi], Int64(190)),
            ([codex] as [any HistoryAdapter], [HistoryAgentID.codex], Int64(120)),
            ([pi, codex] as [any HistoryAdapter], [.codex, .pi], Int64(310)),
        ] {
            let store = HistoryStore.live(adapters: adapters, now: { F.now }, calendar: F.calendar)
            await store.refresh()
            XCTAssertNil(store.error)
            XCTAssertEqual(store.snapshot?.visibleSources.map(\.id), ids)
            XCTAssertEqual(store.snapshot?.sources.count, adapters.count)
            for period in HistoryPeriod.allCases {
                store.period = period
                XCTAssertEqual(store.summary?.tokens, total)
                XCTAssertEqual(
                    store.snapshot?.visibleSources.reduce(Int64(0)) {
                        $0 + ($1.summaries[period]?.tokens ?? 0)
                    },
                    total
                )
            }
        }
        let snapshot = try await codex.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.visibleSources.map(\.id), [.codex])
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 120)
    }

    func testLiveStoreReadsPeriodsFromInjectedRootWithoutAllowanceOrInputWrites() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let now = F.now
        let calendar = F.calendar
        let file = try fixture.write(
            lines: [F.header()]
                + [0, 3, 20].map { days in
                    let date = calendar.date(byAdding: .day, value: -days, to: now)!
                    return message(id: "day-\(days)", at: date)
                }
        )
        let before = try Data(contentsOf: file)
        let history = liveStore(root: fixture.root)
        let allowance = UsageStore(fetch: { throw URLError(.notConnectedToInternet) })
        await allowance.refresh()
        await history.refresh()

        XCTAssertNotNil(allowance.error)
        XCTAssertNil(allowance.snapshot)
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.coverage.state, .ready)
        XCTAssertEqual(history.snapshot?.coverage.hasReadings, true)
        XCTAssertEqual(history.snapshot?.summaries[.today]?.tokens, 190)
        XCTAssertEqual(history.snapshot?.summaries[.week]?.tokens, 380)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 570)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testLiveStoreKeepsFileIndexAcrossRefreshesAndRecoversUnreadableFile() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let now = F.now
        let file = try fixture.write(lines: [F.header(), message(at: now)])
        let history = liveStore(root: fixture.root)
        await history.refresh()
        try fixture.write(lines: [F.header(), message(at: now), message(id: "new", at: now)])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
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
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), message()])
        let history = liveStore(root: fixture.root)
        await history.refresh()
        let previous = try XCTUnwrap(history.snapshot)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fixture.root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.root.path
            )
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: fixture.root.path))
        await history.refresh()
        XCTAssertEqual(history.error, HistoryReadError.unavailable)
        XCTAssertEqual(history.snapshot?.fetchedAt, previous.fetchedAt)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 190)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.root.path
        )
        await history.refresh()
        XCTAssertNil(history.error)
        XCTAssertEqual(history.snapshot?.coverage.state, .ready)
        XCTAssertEqual(history.snapshot?.summaries[.month]?.tokens, 190)
    }

    func testLiveStoreMissingRootIsNotCreatedOrReportedAsObservedZero() async throws {
        let fixture = try HistoryFixtureRoot()
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
        HistoryStore.live(
            adapters: [PiHistorySource(root: root)],
            now: { F.now },
            calendar: F.calendar
        )
    }

    private func message(id: String = "first", at date: Date = F.now) -> String {
        F.message(id: id, time: Int64(date.timeIntervalSince1970 * 1_000))
    }
}
