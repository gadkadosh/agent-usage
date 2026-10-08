import Foundation
import XCTest

@testable import AgentUsage

final class PiHistoryParserTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testNormalizesSubsetsAndIgnoresReportedTotalCostAndContent() {
        let parser = F.parser([
            F.header(),
            F.message(
                extra:
                    #", "content":[{"type":"thinking","thinking":"private-secret"}],"provider":"synthetic","model":"synthetic","newField":true"#
            ),
        ])
        XCTAssertTrue(parser.isSupported)
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertEqual(parser.observations.map(\.tokens), [190])
        XCTAssertEqual(
            parser.observations.first?.timestamp,
            Date(timeIntervalSince1970: Double(F.milliseconds) / 1_000)
        )
        XCTAssertFalse(String(describing: parser).contains("private-secret"))
    }

    func testAllCanonicalUsageSourcesAndAbandonedBranchesAreCountedInV2AndV3() {
        let entries = [
            F.message(), F.message(id: "abandoned", stop: "toolUse"),
            F.message(id: "tool", role: "toolResult"),
            F.entry("usage", id: "cache-warm"), F.entry("compaction", id: "compact"),
            F.entry("branch_summary", id: "branch"),
            F.entry("context_edit", id: "omit-old-message", usage: nil),
        ]
        let legacy = F.parser([F.header(version: 2)] + entries)
        let current = F.parser([F.header(version: 3)] + entries)
        for parser in [legacy, current] {
            XCTAssertTrue(parser.isSupported)
            XCTAssertEqual(parser.issues, [.toolAggregate])
            XCTAssertEqual(parser.observations.reduce(0) { $0 + $1.tokens }, 1_140)
        }
        XCTAssertEqual(legacy.observations, current.observations)
    }

    func testToolAggregateDoesNotAddNestedUsageAgainAndWarnsAboutSavedChildren() {
        let parser = F.parser([
            F.header(),
            F.message(
                role: "toolResult",
                extra:
                    #", "nestedCalls":{"calls":[{"id":"call-a","name":"synthetic","status":"ok","usage":{"input":1000000}}],"complete":true},"details":{"usage":{"input":1000000}}"#
            ),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [190])
        XCTAssertEqual(parser.issues, [.toolAggregate])
    }

    func testPendingAndDeferredExcludedButFinalErrorsAndAbortsWithUsageCount() {
        let parser = F.parser([
            F.header(), F.message(stop: "pending"), F.message(stop: "deferred"),
            F.message(id: "error", stop: "error"), F.message(id: "aborted", stop: "aborted"),
            F.message(id: "length", stop: "length"),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [190, 190, 190])
        XCTAssertTrue(parser.issues.isEmpty)
    }

    func testKnownMetadataAndToolWithoutUsageAreNotGaps() {
        let parser = F.parser([
            F.header(), F.message(role: "toolResult", usage: nil),
            F.message(role: "user", usage: nil), F.message(role: "system", usage: nil),
            F.message(role: "hookMessage", usage: nil),
            F.entry("compaction", id: "old-summary", usage: nil),
            F.entry("branch_summary", id: "old-branch", usage: nil),
            F.entry("custom", id: "custom", usage: nil),
            F.entry("model_change", id: "switch", usage: nil),
        ])
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertTrue(parser.observations.isEmpty)
    }

    func testUnsupportedVersionsAndMissingHeadersNeverInventIDsOrMigrate() {
        // Session version 1 is the legacy linear format, not pi release 1.0.0.
        for header in [
            F.header(version: 1), F.header(version: 4), #"{"type":"session","id":"legacy"}"#,
        ] {
            let parser = F.parser([header, F.message()])
            XCTAssertFalse(parser.isSupported)
            XCTAssertEqual(parser.issues, [.unsupportedVersion])
            XCTAssertTrue(parser.observations.isEmpty)
        }
        XCTAssertFalse(F.parser([F.message()]).isSupported)
        XCTAssertTrue(F.parser([F.header(version: 2), F.message()]).isSupported)
    }

    func testMalformedUnknownAndInvalidRecordsAreCoverageGapsWithoutLeakingPayloads() {
        let parser = F.parser([
            F.header(), "private-secret malformed JSON", F.entry("future-usage", id: "future"),
            F.message(id: "", usage: #"{"input":-1,"output":20,"cacheRead":0,"cacheWrite":0}"#),
            F.message(id: "missing", usage: nil),
            F.message(id: "custom", role: "custom-provider-role"),
            F.message(id: "bad-reason", stop: "future-stop"),
            F.message(
                id: "fraction",
                usage: #"{"input":1.5,"output":0,"cacheRead":0,"cacheWrite":0}"#
            ),
            F.message(
                id: "too-large",
                usage: #"{"input":1000000001,"output":0,"cacheRead":0,"cacheWrite":0}"#
            ),
            F.message(
                id: "bad-subset",
                usage: #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":1}"#
            ),
            F.message(id: "valid"),
        ])
        XCTAssertEqual(parser.observations.count, 1)
        XCTAssertEqual(parser.issues, [.malformedRecord, .unsupportedRecord, .invalidUsage])
        XCTAssertFalse(parser.issues.map(\.description).joined().contains("private-secret"))
    }

    func testPartialFinalLineAndCompleteLineWithoutNewline() {
        var parser = F.parser([F.header()])
        parser.consume(Data(#"{"type":"message","private":"secret""#.utf8), terminated: false)
        XCTAssertEqual(parser.issues, [.incompleteLine])
        parser.consume(Data(F.message().utf8), terminated: false)
        XCTAssertEqual(parser.observations.count, 1)
    }

    func testIdentitySurvivesForksAndParentChangesButNotUnrelatedOperations() {
        let original = F.parser([F.header(), F.message()]).observations[0]
        let fork = F.parser([
            F.header(id: "fork", parent: "/not-followed/source.jsonl"),
            F.message().replacingOccurrences(
                of: "\"parentId\":null",
                with: "\"parentId\":\"changed\""
            ),
        ]).observations[0]
        XCTAssertEqual(original, fork)
        let unrelated = F.parser([F.header(), F.message(time: F.milliseconds + 1)]).observations[0]
        XCTAssertNotEqual(original.operationID, unrelated.operationID)
        let kinds = F.parser([
            F.header(), F.message(), F.message(role: "toolResult"),
            F.entry("usage", id: "operation-a"), F.entry("compaction", id: "operation-a"),
            F.entry("branch_summary", id: "operation-a"),
        ]).observations
        XCTAssertEqual(Set(kinds.map(\.operationID)).count, 5)
    }

    func testCopiesOfEveryUsageKindAggregateOnceWithoutHidingNewWork() {
        let lines = [
            F.message(), F.message(id: "tool-a", role: "toolResult"),
            F.entry("usage", id: "warm-a"), F.entry("compaction", id: "compact-a"),
            F.entry("branch_summary", id: "branch-a"),
        ]
        let original = F.parser([F.header()] + lines).observations
        let copy = F.parser([F.header(id: "clone", parent: "/synthetic/source.jsonl")] + lines)
        XCTAssertEqual(original, copy.observations)
        let newWork = F.parser([F.header(), F.message(id: "new")]).observations
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let summary = PeriodSummary.aggregate(
            original + copy.observations + newWork,
            period: .today,
            now: Date(timeIntervalSince1970: Double(F.milliseconds) / 1_000),
            calendar: calendar
        )
        XCTAssertEqual(summary.tokens, 6 * 190)
        // A conflicting copy must keep its identity so the later index can exclude both.
        let conflict = F.parser([
            F.header(), F.message(usage: #"{"input":1,"output":0,"cacheRead":0,"cacheWrite":0}"#),
        ]).observations[0]
        XCTAssertEqual(original[0].operationID, conflict.operationID)
        XCTAssertNotEqual(original[0], conflict)
    }

    func testMissingInvalidCountsTimestampsAndIDsAreExcludedButZeroIsValid() {
        let badUsages = [
            #"{"input":1,"output":0,"cacheRead":0}"#,
            #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"cacheWrite1h":1}"#,
            #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":-1}"#,
        ]
        var lines = badUsages.map { F.message(usage: $0) }
        lines += [
            F.message(id: ""), F.message(id: String(repeating: "a", count: 257)),
            F.message(time: -1), F.message(time: 32_503_680_000_000),
            F.message().replacingOccurrences(
                of: "\"timestamp\":\(F.milliseconds)",
                with: "\"timestamp\":null"
            ),
            F.entry("usage", id: "bad-time").replacingOccurrences(of: F.timestamp, with: "invalid"),
            F.entry("usage", id: "no-usage", usage: nil),
        ]
        let parser = F.parser(
            [F.header()] + lines + [
                F.message(
                    id: "zero",
                    usage: #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}"#
                )
            ]
        )
        XCTAssertEqual(parser.observations.map(\.tokens), [0])
        XCTAssertEqual(parser.issues, [.invalidUsage])
    }

    func testEmptyInputAndMalformedHeaderDoNotClaimSupport() {
        XCTAssertEqual(F.parser([]).issues, [.incompleteLine])
        let parser = F.parser(["not JSON", F.message()])
        XCTAssertFalse(parser.isSupported)
        XCTAssertTrue(parser.observations.isEmpty)
        XCTAssertEqual(parser.issues, [.malformedRecord, .unsupportedVersion])
    }

    func testEntryTimestampsAcceptSecondsAndIgnoreUnknownPrivateFields() {
        let parser = F.parser([
            F.header(),
            F.entry("usage", id: "seconds").replacingOccurrences(of: ".000Z", with: "Z"),
            F.entry("compaction", id: "summary").replacingOccurrences(
                of: "\"kind\":",
                with: "\"summary\":\"private-secret\",\"details\":{\"arbitrary\":true},\"kind\":"
            ),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [190, 190])
        XCTAssertEqual(parser.observations[0].timestamp, parser.observations[1].timestamp)
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertFalse(String(describing: parser).contains("private-secret"))
    }

    func testInclusiveCutoffUsesUsageTimeRatherThanSessionOrContextTime() {
        let time = Int64(F.since.timeIntervalSince1970 * 1_000)
        let parser = F.parser([
            F.header(), F.message(time: time - 1), F.message(id: "boundary", time: time),
            F.entry("compaction", id: "old").replacingOccurrences(
                of: F.timestamp,
                with: "2026-09-02T23:59:59.999Z"
            ),
            F.entry("usage", id: "boundary-usage").replacingOccurrences(
                of: F.timestamp,
                with: "2026-09-03T00:00:00.000Z"
            ),
        ])
        XCTAssertEqual(parser.observations.map(\.timestamp), [F.since, F.since])
        XCTAssertTrue(parser.issues.isEmpty)
    }

    func testOldOperationsAreFilteredAndSafetyLimitReported() {
        let parser = F.parser(
            [
                F.header(), F.message(id: "old", time: 1_600_000_000_000),
                F.message(), F.message(id: "second"),
            ],
            maxOperations: 1
        )
        XCTAssertEqual(parser.observations.count, 1)
        XCTAssertEqual(parser.issues, [.scanLimit])
    }
}
