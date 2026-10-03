import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class PiHistorySourceTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testDefaultAndCustomRootsWithoutReadingHomeOrAuth() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        for (environment, expected) in [
            ([:], "/synthetic/home/.pi/agent/sessions"),
            (["PI_CODING_AGENT_DIR": "~/agent"], "/synthetic/home/agent/sessions"),
            (["PI_CODING_AGENT_DIR": "/synthetic/agent"], "/synthetic/agent/sessions"),
            (["PI_CODING_AGENT_SESSION_DIR": "~/histories"], "/synthetic/home/histories"),
            (
                [
                    "PI_CODING_AGENT_DIR": "/ignored",
                    "PI_CODING_AGENT_SESSION_DIR": "/synthetic/history",
                ], "/synthetic/history"
            ),
        ] {
            XCTAssertEqual(
                PiHistorySource.defaultRoot(home: home, environment: environment).path, expected)
        }
    }

    func testMissingEmptyUnsupportedAndUnreadableSourcesAreNotZeroReadings() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let missingURL = fixture.root.appendingPathComponent("missing")
        let missing = PiHistorySource(root: missingURL)
        let snapshot = try await missing.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .missing)
        XCTAssertFalse(snapshot.coverage.hasReadings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))

        let source = PiHistorySource(root: fixture.root)
        let empty = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(empty.coverage.state, .missing)
        let file = try fixture.write(lines: [F.header(version: 1), F.message()])
        let unsupported = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(unsupported.coverage.state, .unsupported)
        XCTAssertFalse(unsupported.coverage.hasReadings)
        let unreadableRoot = PiHistorySource(root: file)
        do {
            _ = try await unreadableRoot.refresh(now: F.now, calendar: F.calendar)
            XCTFail("Expected an unavailable directory")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, HistoryReadError.unavailable.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
            XCTAssertTrue(
                HistoryCoverage.limitations.contains { $0.contains("settings.sessionDir") })
        }
    }

    func testForkCloneAndFileCopiesDeduplicateWithoutFollowingParentPathsOrEditingInputs()
        async throws
    {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let original = try fixture.write(lines: [
            F.header(), F.message(), F.message(id: "abandoned"),
        ])
        let before = try Data(contentsOf: original)
        let fork = try fixture.write(
            "--synthetic--/fork.jsonl",
            lines: [
                F.header(id: "fork", parent: "/must-not-be-read/auth.json"), F.message(),
                F.message(id: "fork-new"),
            ])
        let forkBefore = try Data(contentsOf: fork)
        try fixture.write(
            "copy.jsonl", lines: [F.header(), F.message(), F.message(id: "abandoned")])
        let source = PiHistorySource(root: fixture.root)
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertEqual(snapshot.coverage.filesRead, 3)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 570)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try Data(contentsOf: fork), forkBefore)
    }

    func testUnchangedFilesAreCachedAppendReplacementDeletionAndMidnightRefreshCorrectly()
        async throws
    {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [F.header(), F.message()])
        let source = PiHistorySource(root: fixture.root)
        _ = try await source.refresh(now: F.now, calendar: F.calendar)
        _ = try await source.refresh(now: F.now.addingTimeInterval(60), calendar: F.calendar)
        var parsed = await source.filesParsed
        XCTAssertEqual(parsed, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((F.message(id: "new") + "\n").utf8))
        try handle.close()
        let appended = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(appended.summaries[.today]?.tokens, 380)
        parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)
        let tomorrow = try await source.refresh(
            now: F.now.addingTimeInterval(86_400), calendar: F.calendar)
        XCTAssertEqual(tomorrow.summaries[.today]?.tokens, 0)
        XCTAssertEqual(tomorrow.summaries[.week]?.tokens, 380)
        parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)

        // Atomic replacement with the same byte count/mtime still changes the file identity.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try fixture.write(lines: [F.header(), F.message(id: "operation-b"), F.message(id: "new")])
        try FileManager.default.setAttributes(
            [.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        let sameSize = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(sameSize.summaries[.today]?.tokens, 380)
        parsed = await source.filesParsed
        XCTAssertEqual(parsed, 3)
        // In-place same-size edits with restored mtime must invalidate via ctime too.
        let priorBytes = try Data(contentsOf: file)
        let changedBytes = Data(
            String(decoding: priorBytes, as: UTF8.self)
                .replacingOccurrences(of: "\"input\":100", with: "\"input\":200").utf8)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: changedBytes)
        try writer.close()
        try FileManager.default.setAttributes(
            [.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        let edited = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(edited.summaries[.today]?.tokens, 580)
        parsed = await source.filesParsed
        XCTAssertEqual(parsed, 4)
        try fixture.write(lines: [F.header(), F.message(id: "replacement")])
        let replacement = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(replacement.summaries[.today]?.tokens, 190)
        try FileManager.default.removeItem(at: file)
        let deleted = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(deleted.coverage.state, .missing)
        XCTAssertFalse(deleted.coverage.hasReadings)
    }

    func testPartialWritesRecoverAndMixedUnsupportedFilesRemainPartial() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let message = F.message(id: "partial")
        let prefix = String(message.prefix(message.count / 2))
        let file = try fixture.write(lines: [F.header(), F.message(), prefix], ending: "")
        let source = PiHistorySource(root: fixture.root)
        let partial = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(partial.summaries[.today]?.tokens, 190)
        XCTAssertEqual(partial.coverage.state, .partial)
        XCTAssertTrue(partial.coverage.issues.contains(.incompleteLine))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(message.dropFirst(prefix.count)) + "\n").utf8))
        try handle.close()
        let complete = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(complete.summaries[.today]?.tokens, 380)
        XCTAssertEqual(complete.coverage.state, .ready)
        try fixture.write("legacy.jsonl", lines: [F.header(version: 1), F.message()])
        let mixed = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(mixed.coverage.state, .partial)
        XCTAssertEqual(mixed.summaries[.today]?.tokens, 380)
        XCTAssertTrue(mixed.coverage.issues.contains(.unsupportedVersion))
    }

    func testEmptyOrOversizedFileAndScanDepthLimitsAreExplicitGaps() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("empty.jsonl", lines: [], ending: "")
        let source = PiHistorySource(root: fixture.root)
        let empty = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertFalse(empty.coverage.hasReadings)
        XCTAssertTrue(empty.coverage.issues.contains(.incompleteLine))
        try fixture.write("--cwd--/too-deep/session.jsonl", lines: [F.header(), F.message()])
        let bounded = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertTrue(bounded.coverage.issues.contains(.scanLimit))
        XCTAssertEqual(bounded.summaries[.today]?.tokens, 0)
        try fixture.write("large.jsonl", lines: [F.header(), F.message()])
        for limits in [
            PiHistorySource.Limits(fileBytes: 8), .init(refreshBytes: 8),
            .init(visitedEntries: 0),
        ] {
            let limited = PiHistorySource(root: fixture.root, limits: limits)
            let snapshot = try await limited.refresh(now: F.now, calendar: F.calendar)
            XCTAssertTrue(snapshot.coverage.issues.contains(.scanLimit))
            XCTAssertFalse(snapshot.coverage.hasReadings)
        }
    }

    func testRecordsSpanningReadChunksAndCRLFDoNotLoseUsage() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        // Real smoke-check records exceeded 1 MiB; keep this entirely synthetic.
        let contents = String(repeating: "synthetic-private-text", count: 60_000)
        let lines = [
            F.header(),
            "{\"type\":\"custom\",\"id\":\"large-non-usage\",\"data\":\"\(contents)\"}",
            F.message(extra: ",\"content\":\"\(contents)\""),
        ]
        try fixture.write(lines: lines.map { $0 + "\r" }, ending: "\n")
        let source = PiHistorySource(root: fixture.root)
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertFalse(String(describing: snapshot).contains("synthetic-private-text"))
    }

    func testUnreadableChangedFileRetainsLastReadableDataAndRecovers() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [F.header(), F.message()])
        let source = PiHistorySource(root: fixture.root)
        _ = try await source.refresh(now: F.now, calendar: F.calendar)
        try fixture.write(lines: [F.header(), F.message(), F.message(id: "new")])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let stale = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(stale.summaries[.today]?.tokens, 190)
        XCTAssertEqual(stale.coverage.state, .partial)
        XCTAssertTrue(stale.coverage.issues.contains(.staleFile))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recovered = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 380)
        XCTAssertEqual(recovered.coverage.state, .ready)
    }

    func testOperationLimitRetriesAfterCapacityBecomesAvailable() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), F.message(), F.message(id: "new")])
        let source = PiHistorySource(root: fixture.root, limits: .init(operations: 1))
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertTrue(snapshot.coverage.issues.contains(.scanLimit))
        _ = try await source.refresh(now: F.now, calendar: F.calendar)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)
        try fixture.write(lines: [F.header(), F.message()])
        let recovered = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(recovered.coverage.state, .ready)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 190)
    }

    func testRefreshByteBudgetAllowsCachedFilesAndRetriesExcludedFiles() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write("first.jsonl", lines: [F.header(), F.message()])
        try fixture.write("second.jsonl", lines: [F.header(), F.message(id: "operation-b")])
        let size = try Data(contentsOf: file).count
        let source = PiHistorySource(root: fixture.root, limits: .init(refreshBytes: size))
        let limited = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(limited.summaries[.today]?.tokens, 190)
        XCTAssertTrue(limited.coverage.issues.contains(.scanLimit))
        let recovered = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 380)
        XCTAssertEqual(recovered.coverage.state, .ready)
        _ = try await source.refresh(now: F.now, calendar: F.calendar)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 2)
    }

    func testSymlinksAreNotFollowedAndRootFilesMayBeFlat() async throws {
        let fixture = try PiHistoryFixtureRoot()
        let outside = try PiHistoryFixtureRoot()
        defer {
            fixture.remove()
            outside.remove()
        }
        try fixture.write("flat.jsonl", lines: [F.header(), F.message()])
        let outsideFile = try outside.write(lines: [F.header(), F.message(id: "outside")])
        let link = fixture.root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked-directory"),
            withDestinationURL: outside.root)
        let source = PiHistorySource(root: fixture.root)
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertEqual(snapshot.coverage.state, .partial)
    }

    func testConflictingOperationsExcludedRatherThanPickingArbitraryCopy() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("original.jsonl", lines: [F.header(), F.message()])
        try fixture.write(
            "conflict.jsonl",
            lines: [
                F.header(id: "copy"),
                F.message(usage: #"{"input":500,"output":20,"cacheRead":30,"cacheWrite":40}"#),
            ])
        let source = PiHistorySource(root: fixture.root)
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 0)
        XCTAssertTrue(snapshot.coverage.issues.contains(.conflictingOperation))
    }

    func testClockMovingBackwardsReloadsOlderRecordsInsteadOfReusingTrimmedIndex() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let oldTime: Int64 = 1_788_422_400_000  // 2026-09-03 08:00 UTC
        try fixture.write(lines: [F.header(), F.message(time: oldTime)])
        let source = PiHistorySource(root: fixture.root)
        let newer = try await source.refresh(
            now: F.now.addingTimeInterval(86_400), calendar: F.calendar)
        XCTAssertEqual(newer.summaries[.month]?.tokens, 0)
        let older = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(older.summaries[.month]?.tokens, 190)
    }

    func testOversizedAndMalformedRecordsDoNotHideLaterUsage() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let oversized = F.message(
            id: "excluded", extra: ",\"content\":\"\(String(repeating: "x", count: 150_000))\"")
        let file = try fixture.write(lines: [F.header(), oversized, "invalid-json", F.message()])
        let before = try Data(contentsOf: file)
        let source = PiHistorySource(root: fixture.root, limits: .init(lineBytes: 1_024))
        let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertEqual(snapshot.coverage.state, .partial)
        XCTAssertEqual(snapshot.coverage.issues, [.oversizedRecord, .malformedRecord])
        XCTAssertEqual(try Data(contentsOf: file), before)
        // Also exercise an oversized unterminated last record and subsequent replacement.
        try fixture.write(lines: [F.header(), F.message(), oversized], ending: "")
        let partial = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(partial.summaries[.today]?.tokens, 190)
        XCTAssertTrue(partial.coverage.issues.contains(.oversizedRecord))
        try fixture.write(lines: [F.header(), F.message()])
        let recovered = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(recovered.coverage.state, .ready)
    }

    func testChangingReadsAreExcludedAndCancelledReadsDoNotCommitCache() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), F.message()])
        let action = ReadAction()
        let source = PiHistorySource(root: fixture.root, didReadFile: { try action.run() })
        _ = try await source.refresh(now: F.now, calendar: F.calendar)
        try fixture.write(lines: [F.header(), F.message(), F.message(id: "new")])
        action.arm {
            try fixture.write(lines: [F.header(), F.message(id: "replacement")])
        }
        let changing = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(changing.summaries[.today]?.tokens, 190)
        XCTAssertTrue(changing.coverage.issues.contains(.changingFile))
        XCTAssertTrue(changing.coverage.issues.contains(.staleFile))
        let consistent = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(consistent.coverage.state, .ready)
        try fixture.write(lines: [F.header(), F.message(), F.message(id: "new")])
        action.arm { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = Task { try await source.refresh(now: F.now, calendar: F.calendar) }
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await source.refresh(now: F.now, calendar: F.calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 380)
        let parsed = await source.filesParsed
        XCTAssertEqual(parsed, 5)  // Cancelled parsing was retried, not committed.

        let fresh = PiHistorySource(
            root: fixture.root,
            didReadFile: {
                try fixture.write(lines: [F.header(), F.message(id: "different")])
            })
        let excluded = try await fresh.refresh(now: F.now, calendar: F.calendar)
        XCTAssertFalse(excluded.coverage.hasReadings)
        XCTAssertEqual(excluded.summaries[.today]?.tokens, 0)
        XCTAssertTrue(excluded.coverage.issues.contains(.changingFile))
    }

    func testCancellationDoesNotPublishPartialScan() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(lines: [F.header(), F.message()])
        let source = PiHistorySource(root: fixture.root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.refresh(now: F.now, calendar: F.calendar)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
