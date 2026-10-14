import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class OpenCodeHistorySourceTests: XCTestCase {
    private let context = HistoryReadContext(
        now: PiHistoryFixtures.now,
        calendar: PiHistoryFixtures.calendar
    )

    func testAdditiveReasoningCacheCompactionErrorsAndSubagentsWithoutTranscriptOrTotals()
        async throws
    {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.write(extra: [
            "content": [["type": "text", "text": "private transcript"]], "cost": 999,
            "finish": "stop",
        ])
        try fixture.write(id: "failed", extra: ["error": ["message": "private error"]])
        try fixture.write(
            id: "compact",
            type: "compaction",
            extra: ["status": "completed", "summary": "private summary"]
        )
        try fixture.execute("INSERT INTO session_v2 (id, parent_id) VALUES ('child', 'synthetic')")
        try fixture.write(id: "child", session: "child")
        try fixture.write(id: "user", type: "user", tokens: nil, extra: ["text": "private input"])
        try fixture.write(id: "in-flight", tokens: nil)
        let before = try Data(contentsOf: fixture.database)
        let source = OpenCodeHistorySource(database: fixture.database)
        let result = try await source.read(context)
        XCTAssertEqual(result.observations.count, 4)
        XCTAssertEqual(Set(result.observations.map(\.tokens)), [200])
        XCTAssertEqual(result.snapshot(in: context).summaries[.today]?.tokens, 800)
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertTrue(result.coverage.issues.isEmpty)
        XCTAssertFalse(String(describing: result).contains("private"))
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
    }

    func testPeriodsAndForkCopiesDoNotDuplicatePhysicalOperations() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.execute(
            "INSERT INTO session_v2 (id, fork_session_id, time_created) VALUES ('fork', 'synthetic', \(Int64(context.now.timeIntervalSince1970 * 1_000)))"
        )
        for day in [0, 3, 20, 40] {
            let date = context.calendar.date(byAdding: .day, value: -day, to: context.now)!
            try fixture.write(id: "day-\(day)", date: date)
        }
        // The projector gives copied rows new IDs but preserves original timestamps.
        try fixture.write(
            id: "copied-with-new-id",
            date: context.now.addingTimeInterval(-60),
            session: "fork"
        )
        try fixture.write(id: "fork-new", session: "fork")
        let result = try await OpenCodeHistorySource(database: fixture.database).read(context)
        let snapshot = result.snapshot(in: context)
        XCTAssertEqual(result.observations.count, 4)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 400)
        XCTAssertEqual(snapshot.summaries[.week]?.tokens, 600)
        XCTAssertEqual(snapshot.summaries[.month]?.tokens, 800)
    }

    func testWalUpdatesRollbackAndDeletionAreSeenOnRepeatedRefreshes() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try fixture.write()
        let source = OpenCodeHistorySource(database: fixture.database)
        let first = try await source.read(context)
        XCTAssertEqual(first.observations.map(\.tokens), [200])
        try fixture.execute("BEGIN")
        try fixture.write(id: "not-committed")
        let during = try await source.read(context)
        XCTAssertEqual(during.observations.count, 1)
        try fixture.execute("ROLLBACK")
        var tokens = OpenCodeHistoryFixture.tokens
        tokens["input"] = 300
        try fixture.write(tokens: tokens)
        let dbBefore = try Data(contentsOf: fixture.database)
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        let updated = try await source.read(context)
        XCTAssertEqual(updated.observations.map(\.tokens), [400])
        XCTAssertEqual(try Data(contentsOf: fixture.database), dbBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        try fixture.execute("DELETE FROM session_message")
        let deleted = try await source.read(context)
        XCTAssertTrue(deleted.observations.isEmpty)
        XCTAssertEqual(deleted.coverage.state, .ready)
        XCTAssertTrue(deleted.coverage.hasReadings)
    }

    func testMalformedInvalidAndUnknownUsageArePartialNotZeroOrPayloadErrors() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.write()
        try fixture.writeRaw(
            id: "malformed",
            type: "assistant",
            date: context.now,
            data: "private invalid JSON"
        )
        for (index, bad) in ([-1, 1.5, "12", 1_000_000_001] as [Any]).enumerated() {
            var tokens = OpenCodeHistoryFixture.tokens
            tokens["input"] = bad
            try fixture.write(id: "bad-\(index)", tokens: tokens)
        }
        try fixture.write(id: "future", type: "unknown")
        let result = try await OpenCodeHistorySource(database: fixture.database).read(context)
        XCTAssertEqual(result.observations.map(\.tokens), [200])
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(
            result.coverage.issues,
            [.malformedRecord, .invalidUsage, .unsupportedRecord]
        )
        XCTAssertFalse(String(describing: result).contains("private"))
    }

    func testOperationRecordAndSqliteWorkLimitsAreFiniteAndVisible() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.write(id: "a")
        try fixture.write(id: "b")
        let limited = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(operations: 1)
        ).read(context)
        XCTAssertEqual(limited.observations.count, 1)
        XCTAssertEqual(limited.coverage.issues, [.scanLimit])
        XCTAssertFalse(limited.hasMoreFiles)
        let byteLimited = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(refreshBytes: 1)
        )
        .read(context)
        XCTAssertTrue(byteLimited.observations.isEmpty)
        XCTAssertEqual(byteLimited.coverage.issues, [.scanLimit])
        XCTAssertFalse(byteLimited.hasMoreFiles)
        let oversized = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(recordBytes: 1)
        ).read(context)
        XCTAssertTrue(oversized.observations.isEmpty)
        XCTAssertEqual(oversized.coverage.issues, [.oversizedRecord])
        // Allow schema queries to complete but interrupt the larger message scan.
        for i in 0..<100 { try fixture.write(id: "extra-\(i)") }
        let interrupted = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(sqliteSteps: 1_000)
        ).read(context)
        XCTAssertEqual(interrupted.coverage.state, .partial)
        XCTAssertTrue(interrupted.coverage.issues.contains(.scanLimit))
    }

    func testLargeTranscriptsAreExcludedAndSqliteBuffersAreBounded() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.write()
        try fixture.write(
            id: "large",
            extra: ["content": String(repeating: "x", count: 9 * 1_024 * 1_024)]
        )
        let source = OpenCodeHistorySource(database: fixture.database)
        let result = try await source.read(context)
        XCTAssertEqual(result.observations.map(\.tokens), [200])
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(result.coverage.issues, [.oversizedRecord])
        try fixture.write(
            id: "huge",
            extra: ["content": String(repeating: "x", count: 17 * 1_024 * 1_024)]
        )
        do {
            _ = try await source.read(context)
            XCTFail("SQLite's hard buffer limit must reject the read")
        } catch { XCTAssertTrue(error is HistoryReadError) }
    }

    func testMissingLegacyAndUnknownSchemasAreDistinctFromReadableEmptyDatabase() async throws {
        let fixture = try OpenCodeHistoryFixture(schema: false)
        defer { fixture.remove() }
        let source = OpenCodeHistorySource(database: fixture.database)
        let unknown = try await source.read(context)
        XCTAssertEqual(unknown.coverage.state, .unsupported)
        XCTAssertFalse(unknown.coverage.hasReadings)
        try fixture.execute("CREATE TABLE message (id TEXT, data TEXT)")
        let legacy = try await source.read(context)
        XCTAssertEqual(legacy.coverage.state, .unsupported)
        let missing = fixture.root.appendingPathComponent("missing.db")
        let absent = try await OpenCodeHistorySource(database: missing).read(context)
        XCTAssertEqual(absent.coverage.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("storage"),
            withIntermediateDirectories: true
        )
        let jsonLegacy = try await OpenCodeHistorySource(database: missing).read(context)
        XCTAssertEqual(jsonLegacy.coverage.state, .unsupported)
    }

    func testCorruptionSymlinksAndUnreadableFilesFailWithoutCreatingDatabase() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        do {
            _ = try await OpenCodeHistorySource(database: link).read(context)
            XCTFail("Symlink must not be followed")
        } catch { XCTAssertTrue(error is HistoryReadError) }
        let corrupt = fixture.root.appendingPathComponent("corrupt.db")
        try Data("private corrupt content".utf8).write(to: corrupt)
        do {
            _ = try await OpenCodeHistorySource(database: corrupt).read(context)
            XCTFail("Corruption must not become zero usage")
        } catch { XCTAssertTrue(error is HistoryReadError) }
        let sidecar = URL(fileURLWithPath: fixture.database.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: corrupt)
        do {
            _ = try await OpenCodeHistorySource(database: fixture.database).read(context)
            XCTFail("Sidecar links must not be followed")
        } catch { XCTAssertTrue(error is HistoryReadError) }
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fixture.database.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.database.path
            )
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: fixture.database.path))
        do {
            _ = try await OpenCodeHistorySource(database: fixture.database).read(context)
            XCTFail("Unreadable history must not become zero usage")
        } catch { XCTAssertTrue(error is HistoryReadError) }
    }

    func testDiscoveryMatchesXdgAndDatabaseOverrides() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        XCTAssertEqual(
            OpenCodeHistorySource.defaultDatabase(home: home, environment: [:]).path,
            "/synthetic/home/.local/share/opencode/opencode.db"
        )
        XCTAssertEqual(
            OpenCodeHistorySource.defaultDatabase(
                home: home,
                environment: ["XDG_DATA_HOME": "/data", "OPENCODE_DB": "custom.db"]
            ).path,
            "/data/opencode/custom.db"
        )
        XCTAssertEqual(
            OpenCodeHistorySource.defaultDatabase(
                home: home,
                environment: ["OPENCODE_DB": "/custom/opencode.db"]
            ).path,
            "/custom/opencode.db"
        )
    }
}
