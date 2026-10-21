import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class CodexHistorySourceTests: XCTestCase {
    private typealias F = CodexHistoryFixtures
    private var request: HistoryRequest { HistoryRequest(now: F.now, calendar: F.calendar) }

    func testActiveArchivedCopiesAndSubagentsCountOnceAndRefreshReplacesDeletedHistory()
        async throws
    {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let lines = [F.header(), F.durable()]
        let active = try fixture.write("sessions/2026/10/02/rollout-a.jsonl", lines: lines)
        let archived = try fixture.write("archived_sessions/rollout-copy.jsonl", lines: lines)
        try fixture.write(
            "sessions/2026/10/02/rollout-child.jsonl",
            lines: [
                F.header("child"),
                F.durable("response-a", thread: "child", turn: "child-turn", input: 50, output: 10),
            ]
        )
        let before = try Data(contentsOf: active)
        let source = CodexHistorySource(home: fixture.root)
        let first = try await source.read(request)
        XCTAssertEqual(first.observations.map(\.tokens).sorted(), [60, 120])
        XCTAssertEqual(first.coverage.state, .ready)
        XCTAssertEqual(try Data(contentsOf: active), before)
        try FileManager.default.removeItem(at: active)
        try FileManager.default.removeItem(at: archived)
        let second = try await source.read(request)
        XCTAssertEqual(second.observations.map(\.tokens), [60])
    }

    func testConflictingResponseCopiesAreExcludedAndMarkedIncomplete() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("sessions/rollout-a.jsonl", lines: [F.header(), F.durable()])
        try fixture.write(
            "archived_sessions/rollout-b.jsonl",
            lines: [F.header(), F.durable(input: 200)]
        )
        let result = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertEqual(result.observations.count, 0)
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertTrue(result.coverage.issues.contains(.conflictingOperation))
    }

    func testMissingHomeIsNotCreatedAndUnsupportedHistoryIsNotObservedZero() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("missing")
        let result = try await CodexHistorySource(home: home).read(request)
        XCTAssertEqual(result.coverage.state, .missing)
        XCTAssertFalse(result.coverage.hasReadings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try fixture.write("sessions/rollout-invalid.jsonl", lines: [F.start()])
        let invalid = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertFalse(invalid.coverage.hasReadings)
        XCTAssertNotEqual(invalid.coverage.state, .ready)
    }

    func testBatchReplacementIncludesEarlierResultsAndNeverDuplicatesThem() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let first = try fixture.write(
            "sessions/rollout-a.jsonl",
            lines: [F.header(), F.durable("response-a")]
        )
        try fixture.write("sessions/rollout-b.jsonl", lines: [F.header(), F.durable("response-b")])
        let size = try Data(contentsOf: first).count
        let source = CodexHistorySource(home: fixture.root, limits: .init(refreshBytes: size))
        let a = try await source.read(request)
        XCTAssertTrue(a.hasMore)
        XCTAssertEqual(a.observations.count, 1)
        let b = try await source.read(request)
        XCTAssertFalse(b.hasMore)
        XCTAssertEqual(b.observations.count, 2)
        XCTAssertEqual(b.observations.reduce(0) { $0 + $1.tokens }, 240)
    }

    func testDirectoryFailureKeepsAcceptedHistoryWithSourceScopedStaleCoverage() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("sessions/rollout-a.jsonl", lines: [F.header(), F.durable()])
        let root = fixture.root.appendingPathComponent("sessions")
        let source = CodexHistorySource(home: fixture.root)
        _ = try await source.read(request)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: root.path))
        let result = try await source.read(request)
        XCTAssertEqual(result.observations.map(\.tokens), [120])
        XCTAssertTrue(result.coverage.issues.contains(.staleFile))
        XCTAssertEqual(result.coverage.state, .partial)
    }

    func testSymlinkDescendantsAreNotRead() async throws {
        let fixture = try PiHistoryFixtureRoot()
        let outside = try PiHistoryFixtureRoot()
        defer {
            fixture.remove()
            outside.remove()
        }
        let file = try outside.write(lines: [F.header(), F.durable()])
        let directory = fixture.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("rollout-link.jsonl"),
            withDestinationURL: file
        )
        let result = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertEqual(result.observations.count, 0)
        XCTAssertTrue(result.coverage.issues.contains(.unsupportedRecord))
    }

    func testDefaultDiscoveryHonorsOnlyCodexHomeOverride() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        XCTAssertEqual(
            CodexHistorySource.defaultHome(home: home, environment: [:]).path,
            "/synthetic/home/.codex"
        )
        XCTAssertEqual(
            CodexHistorySource.defaultHome(home: home, environment: ["CODEX_HOME": "~/alternate"])
                .path,
            "/synthetic/home/alternate"
        )
        XCTAssertEqual(
            CodexHistorySource.defaultHome(
                home: home,
                environment: ["CODEX_HOME": "/synthetic/codex"]
            ).path,
            "/synthetic/codex"
        )
    }

    func testLiveCompositionCombinesBothInjectedRootsWithoutReadingCredentials() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(
            "pi/session.jsonl",
            lines: [PiHistoryFixtures.header(), PiHistoryFixtures.message()]
        )
        try fixture.write("codex/sessions/rollout-a.jsonl", lines: [F.header(), F.durable()])
        let store = HistoryStore.live(
            root: fixture.root.appendingPathComponent("pi"),
            codexHome: fixture.root.appendingPathComponent("codex"),
            now: { F.now },
            calendar: F.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 310)
        XCTAssertEqual(store.snapshot?.visibleSources.map(\.id), [.codex, .pi])
        for period in HistoryPeriod.allCases {
            store.period = period
            XCTAssertEqual(store.summary?.tokens, 310)
            XCTAssertEqual(
                store.snapshot?.visibleSources.reduce(0) {
                    $0 + ($1.summaries[period]?.tokens ?? 0)
                },
                310
            )
        }
    }
}
