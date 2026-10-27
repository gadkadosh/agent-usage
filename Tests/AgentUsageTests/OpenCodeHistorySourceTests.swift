import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class OpenCodeHistorySourceTests: XCTestCase {
    private typealias F = OpenCodeHistoryFixture
    private let request = HistoryRequest(
        now: HistoryFixtures.now,
        calendar: HistoryFixtures.calendar
    )

    func testDiscoveryHonorsDataAndDatabaseOverridesWithoutCreatingAnything() {
        let home = URL(fileURLWithPath: "/synthetic/home", isDirectory: true)
        for (environment, expected) in [
            ([:], "/synthetic/home/.local/share/opencode/opencode.db"),
            (["XDG_DATA_HOME": "~/data"], "/synthetic/home/data/opencode/opencode.db"),
            (["XDG_DATA_HOME": "/data", "OPENCODE_DB": "other.db"], "/data/opencode/other.db"),
            (["OPENCODE_DB": "~/custom.db"], "/synthetic/home/custom.db"),
            (["OPENCODE_DB": "/custom/usage.db"], "/custom/usage.db"),
            (["XDG_DATA_HOME": ""], "/synthetic/home/.local/share/opencode/opencode.db"),
            (
                ["OPENCODE_CONFIG_DIR": "/not/history"],
                "/synthetic/home/.local/share/opencode/opencode.db"
            ),
        ] {
            XCTAssertEqual(
                OpenCodeHistorySource.defaultDatabaseURL(home: home, environment: environment)?
                    .path,
                expected
            )
        }
        XCTAssertNil(
            OpenCodeHistorySource.defaultDatabaseURL(
                home: home,
                environment: ["OPENCODE_DB": ":memory:"]
            )
        )
    }

    func testCountsResponseSubagentTitleAndCompactionUsageOnceInsideWindow() async throws {
        let fixture = try F()
        try fixture.message()
        try fixture.session("child", parent: "session")
        try fixture.message("msg_child", session: "child")
        try fixture.event("evt_title", type: "session.usage.recorded")  // 2.0 storage
        try fixture.event("evt_compaction", source: "compaction")  // versioned storage
        // The compaction projection is not additional spending.
        try fixture.message("msg_summary", type: "compaction")
        try fixture.message("msg_user", type: "user")
        try fixture.event("evt_response", type: "session.step.ended.1")  // paired durable event
        try fixture.message("msg_unfinished", usage: nil)
        try fixture.message("msg_old", at: request.since.addingTimeInterval(-1))
        try fixture.event("evt_future", at: request.now.addingTimeInterval(1))
        try fixture.execute(
            "INSERT INTO message VALUES ('legacy', '{\"tokens\":9999}'); UPDATE session_v2 SET tokens_input = 9999;"
        )

        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertEqual(
            result.coverage,
            HistoryCoverage(state: .ready, hasReadings: true, issues: [])
        )
        XCTAssertEqual(result.observations.count, 4)
        XCTAssertEqual(total(result), 800)
        XCTAssertEqual(
            Set(result.observations.map(\.operationID)),
            [
                "message:msg_response", "message:msg_child", "event:evt_title",
                "event:evt_compaction",
            ]
        )
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.fetchedAt, request.now)
    }

    func testForkCopiesStayExcludedAfterOriginalDeletionAndReimport() async throws {
        let fixture = try F()
        try fixture.message()
        try fixture.session("fork", fork: "session")
        // Same-millisecond copy cannot be excluded using timestamps alone.
        try fixture.message("msg_forkEvent_1", session: "fork")
        try fixture.message("msg_newResponse", session: "fork")
        try fixture.session("importedFork")  // imports lose fork_session_id but retain message IDs
        try fixture.message("msg_otherForkEvent_2", session: "importedFork")
        let source = OpenCodeHistorySource(database: fixture.database)
        let beforeDeletion = try await source.read(request)
        XCTAssertEqual(total(beforeDeletion), 400)

        // Deleting the ancestor must not promote its surviving copies into new spending.
        try fixture.execute(
            "DELETE FROM session_message WHERE session_id = 'session'; DELETE FROM session_v2 WHERE id = 'session';"
        )
        let result = try await source.read(request)
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertEqual(result.observations.map(\.operationID), ["message:msg_newResponse"])
        XCTAssertEqual(total(result), 200)
    }

    func testSubagentIsNotMistakenForAForkAndCopiedOldActivityIsExcluded() async throws {
        let fixture = try F()
        try fixture.session("child", parent: "session")
        try fixture.message("msg_child", session: "child", at: request.now.addingTimeInterval(-10))
        try fixture.session("fork", fork: "session")
        try fixture.message(
            "msg_olderCopy",
            session: "fork",
            at: request.now.addingTimeInterval(-10)
        )
        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertEqual(result.observations.map(\.operationID), ["message:msg_child"])
        XCTAssertEqual(total(result), 200)
    }

    func testRefreshReplacesCorrectionsAndDeletionsWithoutWritingHistory() async throws {
        let fixture = try F()
        try fixture.message()
        let source = OpenCodeHistorySource(database: fixture.database)
        let dbBefore = try Data(contentsOf: fixture.database)
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        for _ in 0..<2 {
            let result = try await source.read(request)
            XCTAssertEqual(total(result), 200)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), dbBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)

        try fixture.execute(
            "UPDATE session_message SET data = '{\"tokens\":\(F.tokens(input: 50))}';"
        )
        let corrected = try await source.read(request)
        XCTAssertEqual(total(corrected), 150)
        try fixture.execute("DELETE FROM session_message;")
        let empty = try await source.read(request)
        XCTAssertEqual(total(empty), 0)
        XCTAssertEqual(
            empty.coverage,
            HistoryCoverage(state: .ready, hasReadings: true, issues: [])
        )
    }

    func testReadSeesCommittedWALSnapshotNotAnUncommittedWriter() async throws {
        let fixture = try F()
        try fixture.message()
        let source = OpenCodeHistorySource(database: fixture.database)
        try fixture.execute(
            "BEGIN; UPDATE session_message SET data = '{\"tokens\":\(F.tokens(input: 500))}';"
        )
        let uncommitted = try await source.read(request)
        XCTAssertEqual(total(uncommitted), 200)
        try fixture.execute("COMMIT;")
        let committed = try await source.read(request)
        XCTAssertEqual(total(committed), 600)
    }

    func testRejectsInvalidCategoriesAndOverflowWithoutLosingHealthyUsage() async throws {
        let fixture = try F()
        try fixture.message()
        let invalid = [
            F.tokens(input: -1), F.tokens(input: Int64.max),
            "{\"input\":1.5,\"output\":20,\"reasoning\":10,\"cache\":{\"read\":30,\"write\":40}}",
            "{\"input\":true,\"output\":20,\"reasoning\":10,\"cache\":{\"read\":30,\"write\":40}}",
            "{\"input\":\"100\",\"output\":20,\"reasoning\":10,\"cache\":{\"read\":30,\"write\":40}}",
            "{\"input\":100,\"output\":20}", "[]", "1", "null",
            String(data: try JSONEncoder().encode(F.usage), encoding: .utf8)!,
        ]
        for (number, usage) in invalid.enumerated() {
            try fixture.message("msg_bad\(number)", usage: usage)
        }
        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertEqual(total(result), 200)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(
            result.coverage,
            HistoryCoverage(state: .partial, hasReadings: true, issues: [.invalidUsage])
        )
    }

    func testMalformedOnlyReadDoesNotEstablishZeroAndMalformedPayloadIsNotExposed() async throws {
        let fixture = try F()
        try fixture.message()
        try fixture.execute("UPDATE session_message SET data = 'SYNTHETIC MALFORMED TRANSCRIPT';")
        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertEqual(
            result.coverage,
            HistoryCoverage(state: .partial, hasReadings: false, issues: [.malformedRecord])
        )
    }

    func testMalformedTimestampsAndNonObjectRowsAreNotSilentlyMeasuredAsZero() async throws {
        let fixture = try F()
        try fixture.message()
        try fixture.execute("UPDATE session_message SET time_created = 'not-a-timestamp';")
        let source = OpenCodeHistorySource(database: fixture.database)
        let invalidTime = try await source.read(request)
        XCTAssertEqual(
            invalidTime.coverage,
            HistoryCoverage(state: .partial, hasReadings: false, issues: [.malformedRecord])
        )
        try fixture.execute("DELETE FROM session_message;")
        try fixture.message("msg_scalar")
        try fixture.execute("UPDATE session_message SET data = '[]';")
        let invalidObject = try await source.read(request)
        XCTAssertEqual(
            invalidObject.coverage,
            HistoryCoverage(state: .partial, hasReadings: false, issues: [.malformedRecord])
        )
    }

    func testUnknownUsageVersionsAndSourcesArePartialNotAdditionalSpending() async throws {
        let fixture = try F()
        try fixture.message()
        try fixture.event("evt_future", type: "session.usage.recorded.2")
        try fixture.event("evt_unknown", source: "unknown")
        let result = try await OpenCodeHistorySource(database: fixture.database).read(request)
        XCTAssertEqual(total(result), 200)
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(result.coverage.issues, [.unsupportedVersion, .unsupportedRecord])
    }

    func testMissingDatabaseAndEphemeralStorageDoNotCreateFilesOrMeasureZero() async throws {
        let root = try HistoryFixtureRoot()
        defer { root.remove() }
        let missing = root.root.appendingPathComponent("absent/opencode.db")
        for database in [missing, nil] {
            let result = try await OpenCodeHistorySource(database: database).read(request)
            XCTAssertEqual(
                result.coverage,
                HistoryCoverage(state: .missing, hasReadings: false, issues: [])
            )
            XCTAssertTrue(result.observations.isEmpty)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path)
        )
    }

    func testSchemaChangesAndUnusableReadingsPreserveAcceptedUsageAndRecover() async throws {
        let fixture = try F()
        try fixture.message()
        let store = HistoryStore.live(
            adapters: [OpenCodeHistorySource(database: fixture.database)],
            now: { HistoryFixtures.now },
            calendar: HistoryFixtures.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)

        try fixture.execute("ALTER TABLE event RENAME TO unsupported_event;")
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)
        XCTAssertEqual(store.snapshot?.sources.first?.coverage?.state, .unsupported)
        XCTAssertEqual(store.snapshot?.fetchedAt, request.now)

        try fixture.execute(
            "ALTER TABLE unsupported_event RENAME TO event; UPDATE session_message SET data = 'malformed';"
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)
        XCTAssertEqual(store.snapshot?.sources.first?.coverage?.hasReadings, true)
        XCTAssertEqual(store.snapshot?.sources.first?.failed, true)

        try fixture.execute(
            "UPDATE session_message SET data = '{\"tokens\":\(F.tokens(input: 300))}';"
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 400)
        XCTAssertEqual(store.snapshot?.sources.first?.coverage?.state, .ready)
    }

    func testUnreadableDatabaseRetainsUsageAndConfirmedAbsenceClearsIt() async throws {
        let fixture = try F()
        try fixture.message()
        let store = HistoryStore.live(
            adapters: [OpenCodeHistorySource(database: fixture.database)],
            now: { HistoryFixtures.now },
            calendar: HistoryFixtures.calendar
        )
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)
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
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 200)
        XCTAssertEqual(store.snapshot?.sources.first?.failed, true)
        XCTAssertEqual(store.error, .unavailable)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.database.path
        )
        try FileManager.default.removeItem(at: fixture.database)
        await store.refresh()
        XCTAssertEqual(store.summary?.tokens, 0)
        XCTAssertEqual(store.snapshot?.sources.first?.coverage?.state, .missing)
        XCTAssertTrue(store.snapshot?.visibleSources.isEmpty == true)
    }

    func testCorruptDatabaseAndSymlinksAreUnavailableNotMissing() async throws {
        let root = try HistoryFixtureRoot()
        defer { root.remove() }
        let corrupt = try root.write("corrupt.db", lines: ["synthetic non-SQLite content"])
        let fixture = try F()
        let link = root.root.appendingPathComponent("linked.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        for database in [corrupt, link, root.root] {
            do {
                _ = try await OpenCodeHistorySource(database: database).read(request)
                XCTFail("Invalid database must not establish zero")
            } catch { XCTAssertEqual(error as? HistoryReadError, .unavailable) }
        }
    }

    func testPermanentRecordAndWorkBudgetsAreBoundedWithoutContinuation() async throws {
        let fixture = try F()
        for index in 0..<50 { try fixture.message("msg_\(index)") }
        let capped = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(maxRecords: 2)
        ).read(request)
        XCTAssertEqual(total(capped), 400)
        XCTAssertEqual(
            capped.coverage,
            HistoryCoverage(state: .partial, hasReadings: true, issues: [.scanLimit])
        )
        XCTAssertFalse(capped.hasMore)

        let interrupted = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(maxSteps: 0)
        ).read(request)
        XCTAssertTrue(interrupted.observations.isEmpty)
        XCTAssertEqual(
            interrupted.coverage,
            HistoryCoverage(state: .partial, hasReadings: false, issues: [.scanLimit])
        )
        XCTAssertFalse(interrupted.hasMore)
    }

    private func total(_ result: HistoryAdapterResult) -> Int64 {
        historySummaries(result.observations, now: request.now, calendar: request.calendar)[.month]!
            .tokens
    }
}
