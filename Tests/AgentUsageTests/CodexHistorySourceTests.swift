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
        let fixture = try HistoryFixtureRoot()
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

    func testForkReplayDoesNotDuplicateParentSpendingWithOrWithoutCopiedHistory() async throws {
        for copied in [false, true] {
            let fixture = try HistoryFixtureRoot()
            defer { fixture.remove() }
            let parent = [F.header(), F.start(), F.counter()]
            let child =
                [F.header("child", fork: "thread-a")]
                + (copied ? parent : [])
                + [
                    F.settings("child"), F.start("child-turn"), F.counter(),
                    F.durable(
                        "child-response",
                        thread: "child",
                        turn: "child-turn",
                        input: 50,
                        output: 10
                    ),
                    F.counter(150, 30, lastInput: 50, lastOutput: 10),
                ]
            try fixture.write("sessions/parent.jsonl", lines: parent)
            try fixture.write("sessions/child.jsonl", lines: child)
            try fixture.write(
                "archived_sessions/child-copy.jsonl",
                lines: child.map {
                    $0.replacingOccurrences(of: "2026-10-02", with: "2026-10-03")
                }
            )
            let source = CodexHistorySource(home: fixture.root)
            for _ in 0..<2 {
                let result = try await source.read(request)
                XCTAssertEqual(result.observations.map(\.tokens).sorted(), [60, 120])
                XCTAssertEqual(result.coverage.state, copied ? .ready : .partial)
                XCTAssertEqual(result.coverage.issues, copied ? [] : [.unsupportedRecord])
            }
        }
    }

    func testWorldStateAndLocalSettingsDoNotMakeReadableHistoryPartial() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(
            "sessions/rollout.jsonl",
            lines: [
                F.header(), F.start(), F.line("world_state", ["full": true, "state": [:]]),
                F.settings("thread-a"), F.durable(), F.counter(),
            ]
        )
        let source = CodexHistorySource(home: fixture.root)
        for _ in 0..<2 {
            let result = try await source.read(request)
            XCTAssertEqual(result.observations.map(\.tokens), [120])
            XCTAssertEqual(result.coverage.state, .ready)
            XCTAssertEqual(result.coverage.issues, [])
            XCTAssertNil(result.coverage.warning)
        }
    }

    func testMatchingUsageSurvivesDifferentOptionalMetadataAcrossCopies() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("sessions/rollout.jsonl", lines: [F.header(), F.durable()])
        try fixture.write(
            "archived_sessions/copy.jsonl",
            lines: [
                F.header(),
                F.line("turn_context", ["turn_id": "turn-a", "model": "invented-model"]),
                F.durable(),
            ]
        )
        let result = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertEqual(result.observations.map(\.tokens), [120])
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertEqual(result.coverage.issues, [])
    }

    func testCounterResetsKeepDistinctSpendingAndRewrittenCopiesStillDeduplicate() async throws {
        for reset in [
            F.counter(0, 0),
            F.line(
                "event_msg",
                [
                    "type": "token_count", "info": ["total_token_usage": F.tokens(-1, 0)],
                ]
            ),
        ] {
            let fixture = try HistoryFixtureRoot()
            defer { fixture.remove() }
            let lines = [
                F.header(), F.start(), F.counter(), reset,
                F.counter().replacingOccurrences(of: F.time, with: "2026-10-02T11:00:00.000Z"),
            ]
            try fixture.write("sessions/rollout.jsonl", lines: lines)
            let source = CodexHistorySource(home: fixture.root)
            let original = try await source.read(request)
            XCTAssertEqual(original.observations.map(\.tokens).sorted(), [120, 120])
            XCTAssertEqual(original.coverage.issues, [.invalidUsage])
            try fixture.write(
                "archived_sessions/copy.jsonl",
                lines: lines.map {
                    $0.replacingOccurrences(of: "2026-10-02", with: "2026-10-03")
                }
            )
            for _ in 0..<2 {
                let copied = try await source.read(request)
                XCTAssertEqual(copied.observations.map(\.tokens).sorted(), [120, 120])
                XCTAssertEqual(
                    Set(copied.observations.map(\.timestamp)),
                    Set(original.observations.map(\.timestamp))
                )
                XCTAssertEqual(copied.coverage.issues, [.invalidUsage])
            }
        }
    }

    func testRetainedRootsKeepTheirAcceptedFreshnessUntilRecoveryOrDeletion() async throws {
        for failedRoot in ["sessions", "archived_sessions"] {
            let healthyRoot = failedRoot == "sessions" ? "archived_sessions" : "sessions"
            for hasHealthyRoot in [false, true] {
                let fixture = try HistoryFixtureRoot()
                defer { fixture.remove() }
                let path = "\(failedRoot)/rollout.jsonl"
                let file = try fixture.write(path, lines: [F.header(), F.durable()])
                if hasHealthyRoot {
                    try fixture.write(
                        "\(healthyRoot)/rollout.jsonl",
                        lines: [F.header("other"), F.durable(thread: "other")]
                    )
                }
                let service = HistoryService(adapters: [CodexHistorySource(home: fixture.root)])
                let initial = try await service.refresh(now: F.now, calendar: F.calendar)
                XCTAssertEqual(initial.fetchedAt, F.now)
                try fixture.write(path, lines: [F.start()])
                let later = F.now.addingTimeInterval(3_600)
                let stale = try await service.refresh(now: later, calendar: F.calendar)
                XCTAssertEqual(stale.fetchedAt, F.now)
                XCTAssertEqual(stale.sources.first?.fetchedAt, F.now)
                XCTAssertEqual(stale.summaries[.today]?.tokens, hasHealthyRoot ? 240 : 120)
                XCTAssertTrue(stale.coverage.issues.contains(.staleFile))

                try fixture.write(path, lines: [F.header(), F.durable()])
                let recovered = try await service.refresh(now: later, calendar: F.calendar)
                XCTAssertEqual(recovered.fetchedAt, later)
                XCTAssertEqual(recovered.coverage.state, .ready)
                try FileManager.default.removeItem(at: file)
                let deleted = try await service.refresh(
                    now: later.addingTimeInterval(3_600),
                    calendar: F.calendar
                )
                XCTAssertEqual(deleted.fetchedAt, later.addingTimeInterval(3_600))
                XCTAssertEqual(deleted.summaries[.today]?.tokens, hasHealthyRoot ? 120 : 0)
            }
        }
    }

    func testConflictingResponseCopiesAreExcludedAndMarkedIncomplete() async throws {
        let fixture = try HistoryFixtureRoot()
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

    func testRewrittenCopiesCannotMoveOldUsageIntoTheWindowAcrossRefreshes() async throws {
        for durable in [true, false] {
            for originalRoot in ["sessions", "archived_sessions"] {
                let fixture = try HistoryFixtureRoot()
                defer { fixture.remove() }
                let copyRoot = originalRoot == "sessions" ? "archived_sessions" : "sessions"
                let record = durable ? F.durable() : F.counter()
                let oldRecord = record.replacingOccurrences(
                    of: F.time,
                    with: "2026-08-01T10:00:00.000Z"
                )
                try fixture.write(
                    "\(copyRoot)/rollout-copy.jsonl",
                    lines: [F.header(), F.start(), record]
                )
                let source = CodexHistorySource(home: fixture.root)
                let initial = try await source.read(request)
                XCTAssertEqual(initial.observations.map(\.tokens), [120])
                let original = try fixture.write(
                    "\(originalRoot)/rollout-original.jsonl",
                    lines: [F.header(), F.start(), oldRecord]
                )
                for _ in 0..<2 {
                    let result = try await source.read(request)
                    XCTAssertEqual(
                        result.observations,
                        [],
                        "Old canonical activity is outside the window"
                    )
                    XCTAssertEqual(result.coverage.state, .ready)
                }
                try FileManager.default.removeItem(at: original)
                let removed = try await source.read(request)
                XCTAssertEqual(removed.observations.map(\.tokens), [120])
            }
        }
    }

    func testOlderMetadataStillObeysTheOperationLimit() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let old = F.durable().replacingOccurrences(
            of: F.time,
            with: "2026-08-01T10:00:00.000Z"
        )
        try fixture.write(
            "sessions/rollout.jsonl",
            lines: [F.header(), old, F.durable("recent")]
        )
        let source = CodexHistorySource(home: fixture.root, limits: .init(operations: 1))
        for _ in 0..<2 {
            let result = try await source.read(request)
            XCTAssertEqual(result.observations, [])
            XCTAssertEqual(result.coverage.state, .partial)
            XCTAssertTrue(result.coverage.issues.contains(.scanLimit))
            XCTAssertFalse(result.hasMore, "A permanent limit must not cause endless catch-up")
        }
    }

    func testOldConflictingCopyStillInvalidatesRecentUsage() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("sessions/rollout-copy.jsonl", lines: [F.header(), F.durable()])
        let old = F.durable(input: 200).replacingOccurrences(
            of: F.time,
            with: "2026-08-01T10:00:00.000Z"
        )
        try fixture.write("archived_sessions/rollout-original.jsonl", lines: [F.header(), old])
        let result = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertEqual(result.observations, [])
        XCTAssertTrue(result.coverage.issues.contains(.conflictingOperation))
    }

    func testMissingHomeIsNotCreatedAndUnsupportedHistoryIsNotObservedZero() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("missing")
        let result = try await CodexHistorySource(home: home).read(request)
        XCTAssertEqual(result.coverage.state, .missing)
        XCTAssertFalse(result.coverage.hasReadings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try fixture.write("sessions/rollout-invalid.jsonl", lines: [F.start()])
        let invalid = try await CodexHistorySource(home: fixture.root).read(request)
        XCTAssertFalse(invalid.coverage.hasReadings)
        XCTAssertEqual(invalid.coverage.state, .unsupported)
    }

    func testBatchReplacementIncludesEarlierResultsAndNeverDuplicatesThem() async throws {
        let fixture = try HistoryFixtureRoot()
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

    func testCatchUpReadsDeferredFilesAfterAnUnusableBatch() async throws {
        for deferredRoot in ["sessions", "archived_sessions"] {
            let otherRoot = deferredRoot == "sessions" ? "archived_sessions" : "sessions"
            for hasPriorReadings in [true, false] {
                for hasOtherRoot in [true, false] {
                    let fixture = try HistoryFixtureRoot()
                    defer { fixture.remove() }
                    for name in ["a", "b"] {
                        try fixture.write("\(deferredRoot)/\(name).jsonl", lines: [F.start()])
                    }
                    let root = fixture.root.appendingPathComponent(deferredRoot)
                    let enumerator = try XCTUnwrap(
                        FileManager.default.enumerator(
                            at: root,
                            includingPropertiesForKeys: nil
                        )
                    )
                    let files = enumerator.allObjects.compactMap { $0 as? URL }
                    XCTAssertEqual(files.count, 2)
                    let first = try XCTUnwrap(files.first)
                    let last = try XCTUnwrap(files.last)
                    if hasOtherRoot {
                        try fixture.write(
                            "\(otherRoot)/healthy.jsonl",
                            lines: [
                                F.header("healthy"),
                                F.durable("healthy", thread: "healthy", input: 20, output: 10),
                            ]
                        )
                    }
                    let service = HistoryService(adapters: [
                        CodexHistorySource(home: fixture.root, limits: .init(refreshBytes: 1_000))
                    ])
                    if hasPriorReadings {
                        try Data(([F.header(), F.durable()].joined(separator: "\n") + "\n").utf8)
                            .write(to: first)
                        let initial = try await service.refresh(now: F.now, calendar: F.calendar)
                        XCTAssertEqual(initial.summaries[.today]?.tokens, hasOtherRoot ? 150 : 120)
                    }
                    // One unsupported file fills the batch without hitting a permanent limit.
                    // Overwrite in place to preserve the enumeration order observed above.
                    let invalid =
                        F.start() + String(repeating: " ", count: 999 - F.start().utf8.count)
                    try Data((invalid + "\n").utf8).write(to: first)
                    try Data(
                        ([
                            F.header("new"), F.durable("new", thread: "new", input: 50, output: 10),
                        ].joined(separator: "\n") + "\n").utf8
                    ).write(to: last)
                    let completed = try await service.refresh(now: F.now, calendar: F.calendar)
                    XCTAssertEqual(completed.summaries[.today]?.tokens, hasOtherRoot ? 90 : 60)
                    XCTAssertEqual(completed.coverage.state, .partial)
                    XCTAssertEqual(completed.coverage.issues, [.unsupportedVersion])
                    XCTAssertFalse(completed.hasMore)
                }
            }
        }
    }

    func testDirectoryFailureKeepsAcceptedHistoryWithSourceScopedStaleCoverage() async throws {
        let fixture = try HistoryFixtureRoot()
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

    func testUnusableRootRetainsReadingsWhileOtherRootAdvancesAndRecoveryReplacesThem()
        async throws
    {
        for failedRoot in ["sessions", "archived_sessions"] {
            let healthyRoot = failedRoot == "sessions" ? "archived_sessions" : "sessions"
            for replacement in [F.start(), "{not-json}"] {
                for hasHealthyRoot in [true, false] {
                    let fixture = try HistoryFixtureRoot()
                    defer { fixture.remove() }
                    let path = "\(failedRoot)/rollout.jsonl"
                    try fixture.write(path, lines: [F.header(), F.durable()])
                    if hasHealthyRoot {
                        try fixture.write(
                            "\(healthyRoot)/rollout.jsonl",
                            lines: [
                                F.header("other"),
                                F.durable("other", thread: "other", input: 50, output: 10),
                            ]
                        )
                    }
                    let service = HistoryService(adapters: [CodexHistorySource(home: fixture.root)])
                    let initial = try await service.refresh(now: F.now, calendar: F.calendar)
                    XCTAssertEqual(initial.summaries[.today]?.tokens, hasHealthyRoot ? 180 : 120)

                    try fixture.write(path, lines: [replacement])
                    if hasHealthyRoot {
                        try fixture.write(
                            "\(healthyRoot)/rollout.jsonl",
                            lines: [
                                F.header("other"),
                                F.durable("other", thread: "other", input: 80, output: 10),
                            ]
                        )
                    }
                    let healthyTokens: Int64 = hasHealthyRoot ? 90 : 0
                    for _ in 0..<2 {
                        let stale = try await service.refresh(now: F.now, calendar: F.calendar)
                        XCTAssertEqual(stale.summaries[.today]?.tokens, 120 + healthyTokens)
                        XCTAssertEqual(stale.coverage.state, .partial)
                        XCTAssertTrue(stale.coverage.issues.contains(.staleFile))
                        XCTAssertTrue(
                            stale.coverage.issues.contains(
                                replacement == F.start() ? .unsupportedVersion : .malformedRecord
                            )
                        )
                        XCTAssertEqual(
                            stale.sources.first?.status,
                            "Incomplete history. Includes older readings."
                        )
                        XCTAssertFalse(stale.hasMore)
                    }

                    try fixture.write(path, lines: [F.header(), F.durable(input: 200)])
                    let recovered = try await service.refresh(now: F.now, calendar: F.calendar)
                    XCTAssertEqual(recovered.summaries[.today]?.tokens, 220 + healthyTokens)
                    XCTAssertEqual(recovered.coverage.state, .ready)
                    XCTAssertEqual(recovered.coverage.issues, [])

                    // A readable empty history and confirmed deletion still clear old usage.
                    try fixture.write(path, lines: [F.header()])
                    let empty = try await service.refresh(now: F.now, calendar: F.calendar)
                    XCTAssertEqual(empty.summaries[.today]?.tokens, healthyTokens)
                    XCTAssertEqual(empty.coverage.state, .ready)
                    try FileManager.default.removeItem(
                        at: fixture.root.appendingPathComponent(path)
                    )
                    let deleted = try await service.refresh(now: F.now, calendar: F.calendar)
                    XCTAssertEqual(deleted.summaries[.today]?.tokens, healthyTokens)
                    XCTAssertFalse(deleted.coverage.issues.contains(.staleFile))
                }
            }
        }
    }

    func testInitiallyUnusableRootDoesNotInventReadingsOrStaleStatus() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("sessions/rollout.jsonl", lines: ["{not-json}"])
        try fixture.write(
            "archived_sessions/rollout.jsonl",
            lines: [F.header(), F.durable()]
        )
        let source = CodexHistorySource(home: fixture.root)
        let first = try await source.read(request)
        XCTAssertEqual(first.observations.map(\.tokens), [120])
        XCTAssertEqual(first.coverage.state, .partial)
        XCTAssertEqual(first.coverage.issues, [.malformedRecord])
        try fixture.write(
            "sessions/rollout.jsonl",
            lines: [F.header("new"), F.durable(thread: "new")]
        )
        let recovered = try await source.read(request)
        XCTAssertEqual(recovered.observations.map(\.tokens), [120, 120])
        XCTAssertEqual(recovered.coverage.state, .ready)
        XCTAssertEqual(recovered.coverage.issues, [])
    }

    func testSymlinkDescendantsAreNotRead() async throws {
        let fixture = try HistoryFixtureRoot()
        let outside = try HistoryFixtureRoot()
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
}
