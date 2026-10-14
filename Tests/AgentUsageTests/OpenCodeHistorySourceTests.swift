import Foundation
import SQLite3
import XCTest

@testable import AgentUsage

final class OpenCodeHistorySourceTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testDefaultDiscoveryHonorsXDGAndDatabaseOverrideWithoutReadingSettings() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        let cases: [([String: String], String?)] = [
            ([:], "/synthetic/home/.local/share/opencode/opencode.db"),
            (["XDG_DATA_HOME": "/synthetic/data"], "/synthetic/data/opencode/opencode.db"),
            (["OPENCODE_DB": "custom.db"], "/synthetic/home/.local/share/opencode/custom.db"),
            (["OPENCODE_DB": "/synthetic/custom.db"], "/synthetic/custom.db"),
            (["OPENCODE_DB": ":memory:"], nil),
        ]
        for (environment, expected) in cases {
            XCTAssertEqual(
                OpenCodeHistorySource.defaultDatabase(home: home, environment: environment)?.path,
                expected
            )
        }
    }

    func testReadsAllTokenCategoriesIntoPeriodsAndBucketsWithoutModifyingDatabase() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        for (seq, days) in [0, 3, 20, 31].enumerated() {
            let date = F.calendar.date(byAdding: .day, value: -days, to: F.now)!
            try fixture.message(id: "msg_day\(days)", seq: seq, at: date)
        }
        let before = try Data(contentsOf: fixture.database)
        let source = OpenCodeHistorySource(database: fixture.database)
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertTrue(snapshot.coverage.hasReadings)
        for (period, expected) in [(HistoryPeriod.today, Int64(200)), (.week, 400), (.month, 600)] {
            XCTAssertEqual(snapshot.summaries[period]?.tokens, expected)
            XCTAssertEqual(
                snapshot.summaries[period]?.buckets.reduce(0) { $0 + $1.tokens },
                expected
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
    }

    func testCountsCompactionAndErrorUsageButNotSessionTotalsEventsOrPendingMessages() async throws
    {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        try fixture.message(id: "msg_compact", seq: 2, type: "compaction")
        try fixture.message(
            id: "msg_error",
            seq: 3,
            data: fixture.usage().replacingOccurrences(
                of: "\"cost\":9876",
                with: "\"error\":{},\"cost\":0"
            )
        )
        try fixture.message(id: "msg_pending", seq: 4, data: "{}")
        try fixture.message(id: "msg_user", seq: 5, type: "user")
        try fixture.execute(
            "ALTER TABLE session_v2 ADD COLUMN tokens_input INTEGER DEFAULT 99999999; CREATE TABLE event (data TEXT); INSERT INTO event VALUES ('sensitive invented payload')"
        )
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 600)
        XCTAssertEqual(snapshot.coverage.state, .ready)
    }

    func testForksNestedForksAndDeletedOriginsDoNotCountCopiedHistoryTwice() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message()
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_1", session: "fork", data: original)
        let newRequestDate = F.now.addingTimeInterval(-60)
        try fixture.message(id: "msg_newrequest", session: "fork", seq: 5, at: newRequestDate)
        try fixture.session("nested", fork: "fork")
        try fixture.message(id: "msg_nestedevent_1", session: "nested", data: original)
        try fixture.message(id: "msg_nestedevent_5", session: "nested", seq: 5, at: newRequestDate)
        try fixture.session("subagent")
        try fixture.message(id: "msg_childrequest", session: "subagent")
        let complete = try await read(fixture)
        XCTAssertEqual(complete.summaries[.today]?.tokens, 600)
        try fixture.execute(
            "DELETE FROM session_message WHERE session_id = 'original'; DELETE FROM session_v2 WHERE id = 'original'"
        )
        let retained = try await read(fixture)
        XCTAssertEqual(retained.summaries[.today]?.tokens, 600)
        XCTAssertEqual(retained.coverage.state, .partial)
        XCTAssertTrue(retained.coverage.issues.contains(.unresolvedFork))
    }

    func
        testUnrelatedRequestsAndCopiesWithDifferentUsageArePreserved()
        async throws
    {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        try fixture.session("unrelated")
        try fixture.message(id: "msg_other", session: "unrelated")
        let separate = try await read(fixture)
        XCTAssertEqual(separate.summaries[.today]?.tokens, 400)
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_1", session: "fork", data: fixture.usage(input: 101))
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 601)
        XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
    }

    func testReimportedParentSequencesDoNotDiscardUnrelatedUsage() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message(seq: 2)
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_2", session: "fork", seq: 2, data: original)
        try fixture.session("nested", fork: "fork")
        try fixture.message(id: "msg_nestedevent_2", session: "nested", seq: 2, data: original)
        try fixture.execute("UPDATE session_message SET seq = 1 WHERE session_id = 'original'")
        try fixture.message(id: "msg_unrelated", seq: 2, data: fixture.usage(input: 200))
        let before = try Data(contentsOf: fixture.database)

        let reimported = try await read(fixture)
        XCTAssertEqual(reimported.summaries[.today]?.tokens, 500)
        XCTAssertEqual(reimported.observations.count, 2)
        XCTAssertEqual(reimported.coverage.state, .ready)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)

        // An import may also omit the copied request while reusing its former sequence.
        try fixture.execute("DELETE FROM session_message WHERE id = 'msg_first'")
        let omitted = try await read(fixture)
        XCTAssertEqual(omitted.summaries[.today]?.tokens, 500)
        XCTAssertEqual(omitted.observations.count, 2)
        XCTAssertEqual(omitted.coverage.issues, [.unresolvedFork])
    }

    func testReimportedForkAndIntermediateAncestorKeepCopiedIdentity() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message(seq: 2)
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_2", session: "fork", seq: 2, data: original)
        try fixture.session("nested", fork: "fork")
        try fixture.message(id: "msg_nestedevent_2", session: "nested", seq: 2, data: original)
        try fixture.execute("UPDATE session_message SET seq = 1 WHERE session_id != 'original'")
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 200)
        XCTAssertEqual(snapshot.observations.count, 1)
        XCTAssertEqual(snapshot.coverage.state, .ready)
    }

    func testImportedCopyWithoutStoredAncestryRetainsUsageAndWarns() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message(seq: 2)
        // v2.0.25 import preserves copied IDs but does not restore fork_session_id.
        try fixture.session("imported")
        try fixture.message(id: "msg_forkevent_2", session: "imported", seq: 1, data: original)
        for seq in [1, 2] {
            try fixture.execute(
                "UPDATE session_message SET seq = \(seq) WHERE session_id = 'imported'"
            )
            let snapshot = try await read(fixture)
            XCTAssertEqual(snapshot.summaries[.today]?.tokens, 400)
            XCTAssertEqual(snapshot.observations.count, 2)
            XCTAssertEqual(snapshot.coverage.state, .partial)
            XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
        }
    }

    func testRenumberedSiblingCopiesWithDeletedOriginAreRetainedAsAmbiguous() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_2", session: "fork", seq: 1)
        try fixture.session("sibling", fork: "original")
        try fixture.message(id: "msg_siblingevent_2", session: "sibling", seq: 9)
        try fixture.execute("DELETE FROM session_v2 WHERE id = 'original'")
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 400)
        XCTAssertEqual(snapshot.observations.count, 2)
        XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
    }

    func testReusedParentSequenceDoesNotMergeDistinctSurvivorsAfterDeletion() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let first = try fixture.message(seq: 2)
        try fixture.session("first-fork", fork: "original")
        try fixture.message(id: "msg_firstfork_2", session: "first-fork", seq: 2, data: first)
        try fixture.execute("DELETE FROM session_message WHERE session_id = 'original'")
        // A re-import can reuse the sequence for another ID, even with identical metadata.
        let second = try fixture.message(id: "msg_distinct", seq: 2)
        try fixture.session("second-fork", fork: "original")
        try fixture.message(id: "msg_secondfork_2", session: "second-fork", seq: 2, data: second)
        try fixture.execute(
            "DELETE FROM session_message WHERE session_id = 'original'; DELETE FROM session_v2 WHERE id = 'original'"
        )
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 400)
        XCTAssertEqual(snapshot.observations.count, 2)
        XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
    }

    func testAmbiguousParentMetadataDoesNotMergeDistinctRequests() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message()
        try fixture.message(id: "msg_identical", seq: 2, data: original)
        try fixture.session("fork", fork: "original")
        try fixture.message(id: "msg_forkevent_1", session: "fork", data: original)

        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 600)
        XCTAssertEqual(snapshot.observations.count, 3)
        XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
    }

    func testForkAncestryMustMatchRequestTypeAndTimestampNotJustTokens() async throws {
        for changedType in [false, true] {
            let fixture = try OpenCodeHistoryFixture()
            defer { fixture.remove() }
            try fixture.message()
            try fixture.session("fork", fork: "original")
            try fixture.message(
                id: "msg_forkevent_1",
                session: "fork",
                type: changedType ? "compaction" : "assistant",
                at: changedType ? F.now : F.now.addingTimeInterval(-60)
            )
            let snapshot = try await read(fixture)
            XCTAssertEqual(snapshot.summaries[.today]?.tokens, 400)
            XCTAssertEqual(snapshot.coverage.issues, [.unresolvedFork])
        }
    }

    func testRefreshReplacesUpdatedUsageAndDropsDeletedRequestsAndDoesNotCountFutureRequests()
        async throws
    {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        let source = OpenCodeHistorySource(database: fixture.database)
        let initial = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(initial.summaries[.today]?.tokens, 200)
        try fixture.execute(
            "UPDATE session_message SET data = replace(data, '\"input\":100', '\"input\":300')"
        )
        try fixture.message(id: "msg_future", seq: 2, at: F.now.addingTimeInterval(3600))
        let updated = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(updated.summaries[.today]?.tokens, 400)
        try fixture.execute("DELETE FROM session_message WHERE seq = 1")
        let empty = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(empty.summaries[.today]?.tokens, 0)
        XCTAssertTrue(empty.coverage.hasReadings)
    }

    func testMalformedAndInvalidUsageCannotTurnIntoRecordedZero() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        try fixture.message(id: "msg_malformed", seq: 2, data: "{broken invented text")
        try fixture.message(id: "msg_negative", seq: 3, data: fixture.usage(input: -1))
        try fixture.message(id: "msg_missing", seq: 4, data: "{\"tokens\":{\"input\":100}}")
        try fixture.message(id: "msg_oversize", seq: 5, data: fixture.usage(input: 1_000_000_001))
        let snapshot = try await read(fixture)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 200)
        XCTAssertEqual(snapshot.coverage.state, .partial)
        XCTAssertTrue(snapshot.coverage.issues.contains(.invalidUsage))
        XCTAssertTrue(snapshot.coverage.issues.contains(.malformedRecord))
    }

    func testMissingUnsupportedAndCorruptDatabasesAreNotObservedZeroAndMissingPathIsNotCreated()
        async throws
    {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing.db")
        let missingSnapshot = try await OpenCodeHistorySource(database: missing).refresh(
            now: F.now,
            calendar: F.calendar
        )
        XCTAssertEqual(missingSnapshot.coverage.state, .missing)
        XCTAssertFalse(missingSnapshot.coverage.hasReadings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try fixture.execute(
            "DROP TABLE session_message; DROP TABLE session_v2; CREATE TABLE message (data TEXT)"
        )
        let unsupported = try await read(fixture)
        XCTAssertEqual(unsupported.coverage.state, .unsupported)
        XCTAssertFalse(unsupported.coverage.hasReadings)
        try Data("invented invalid database".utf8).write(to: fixture.database)
        do {
            _ = try await read(fixture)
            XCTFail("Corrupt database must fail, not become zero usage")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                HistoryReadError.unavailable.localizedDescription
            )
            XCTAssertFalse(error.localizedDescription.contains("invented"))
        }
    }

    func testWALWritesDuringReadAreVisibleOnlyOnNextRefresh() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let writer = try fixture.open()
        defer { sqlite3_close(writer) }
        try OpenCodeHistoryFixture.execute("PRAGMA journal_mode=WAL", on: writer)
        try fixture.message()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.database.path + "-wal"))
        let source = OpenCodeHistorySource(
            database: fixture.database,
            didReadRow: {
                try fixture.message(id: "msg_concurrent", seq: 2)
            }
        )
        let first = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(first.summaries[.today]?.tokens, 200)
        let second = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(second.summaries[.today]?.tokens, 400)
    }

    func testDeepForkAndCycleSkipOnlyUnresolvableCopiesAndKeepUnrelatedRequests() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        let original = try fixture.message()
        var parent = "original"
        for level in 1...65 {
            let session = "fork-\(level)"
            try fixture.session(session, fork: parent)
            try fixture.message(id: "msg_fork\(level)_1", session: session, data: original)
            parent = session
        }
        try fixture.session("unrelated")
        try fixture.message(id: "msg_independent", session: "unrelated")
        let deep = try await read(fixture)
        XCTAssertEqual(deep.summaries[.today]?.tokens, 400)
        XCTAssertEqual(deep.coverage.state, .partial)
        XCTAssertTrue(deep.coverage.issues.contains(.scanLimit))
        XCTAssertFalse(deep.hasMoreFiles)
        try fixture.session("cycle-a", fork: "cycle-b")
        try fixture.session("cycle-b", fork: "cycle-a")
        try fixture.message(id: "msg_cyclea_1", session: "cycle-a", data: original)
        try fixture.message(id: "msg_cycleb_1", session: "cycle-b", data: original)
        let cyclic = try await read(fixture)
        XCTAssertEqual(cyclic.summaries[.today]?.tokens, 400)
        XCTAssertEqual(cyclic.coverage.state, .partial)
        XCTAssertTrue(cyclic.coverage.issues.contains(.scanLimit))
        XCTAssertFalse(cyclic.hasMoreFiles)
    }

    func testSafetyLimitsExposePartialCoverageWithoutRetryLoop() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        try fixture.message(id: "msg_second", seq: 2)
        let limited = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(operations: 1)
        ).refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(limited.summaries[.today]?.tokens, 200)
        XCTAssertTrue(limited.coverage.issues.contains(.scanLimit))
        XCTAssertFalse(limited.hasMoreFiles)
        let oversized = try await OpenCodeHistorySource(
            database: fixture.database,
            limits: .init(recordBytes: 8)
        ).refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(oversized.summaries[.today]?.tokens, 0)
        XCTAssertEqual(oversized.coverage.state, .partial)
        XCTAssertFalse(oversized.hasMoreFiles)
    }

    func testUnreadableDatabaseAndDirectoryAreUnavailableNotMissingOrRecordedZero() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        for path in [fixture.database, fixture.root] {
            if path == fixture.database {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0],
                    ofItemAtPath: path.path
                )
                if FileManager.default.isReadableFile(atPath: path.path) { continue }
            }
            do {
                _ = try await OpenCodeHistorySource(database: path).refresh(
                    now: F.now,
                    calendar: F.calendar
                )
                XCTFail("Unreadable/non-regular database must fail")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    HistoryReadError.unavailable.localizedDescription
                )
            }
        }
    }

    func testExpiredReadDeadlineFailsInsteadOfPublishingIncompleteZero() async throws {
        let fixture = try OpenCodeHistoryFixture()
        defer { fixture.remove() }
        try fixture.message()
        do {
            _ = try await OpenCodeHistorySource(
                database: fixture.database,
                limits: .init(querySeconds: 0)
            ).refresh(now: F.now, calendar: F.calendar)
            XCTFail("Expired reads must fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                HistoryReadError.unavailable.localizedDescription
            )
        }
    }

    private func read(_ fixture: OpenCodeHistoryFixture) async throws -> HistorySnapshot {
        try await OpenCodeHistorySource(database: fixture.database).refresh(
            now: F.now,
            calendar: F.calendar
        )
    }
}
