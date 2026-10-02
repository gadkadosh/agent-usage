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
            Date(timeIntervalSince1970: Double(F.milliseconds) / 1_000))
        XCTAssertFalse(String(describing: parser.observations).contains("private-secret"))
    }

    func testAllCanonicalUsageSourcesAndAbandonedBranchesAreCounted() {
        let parser = F.parser([
            F.header(), F.message(), F.message(id: "abandoned", stop: "toolUse"),
            F.entry("usage", id: "cache-warm"), F.entry("compaction", id: "compact"),
            F.entry("branch_summary", id: "branch"),
            F.entry("context_edit", id: "omit-old-message", usage: nil),
        ])
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertEqual(parser.observations.reduce(0) { $0 + $1.tokens }, 950)
    }

    func testToolAggregateDoesNotAddNestedUsageAgainAndWarnsAboutSavedChildren() {
        let parser = F.parser([
            F.header(),
            F.message(
                role: "toolResult",
                extra:
                    #", "nestedCalls":[{"usage":{"input":1000000}}],"details":{"usage":{"input":1000000}}"#
            ),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [190])
        XCTAssertEqual(parser.issues, [.toolAggregate])
    }

    func testPendingAndDeferredExcludedButFinalErrorsAndAbortsWithUsageCount() {
        let parser = F.parser([
            F.header(), F.message(stop: "pending"), F.message(stop: "deferred"),
            F.message(id: "error", stop: "error"), F.message(id: "aborted", stop: "aborted"),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [190, 190])
        XCTAssertTrue(parser.issues.isEmpty)
    }

    func testKnownMetadataAndToolWithoutUsageAreNotGaps() {
        let parser = F.parser([
            F.header(), F.message(role: "toolResult", usage: nil),
            F.message(role: "user", usage: nil),
            F.entry("compaction", id: "old-summary", usage: nil),
            F.entry("branch_summary", id: "old-branch", usage: nil),
            F.entry("custom", id: "custom", usage: nil),
            F.entry("model_change", id: "switch", usage: nil),
        ])
        XCTAssertTrue(parser.issues.isEmpty)
        XCTAssertTrue(parser.observations.isEmpty)
    }

    func testUnsupportedVersionsAndMissingHeadersNeverInventIDsOrMigrate() {
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
                id: "fraction", usage: #"{"input":1.5,"output":0,"cacheRead":0,"cacheWrite":0}"#),
            F.message(
                id: "too-large",
                usage: #"{"input":1000000001,"output":0,"cacheRead":0,"cacheWrite":0}"#),
            F.message(
                id: "bad-subset",
                usage: #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":1}"#),
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
                of: "\"parentId\":null", with: "\"parentId\":\"changed\""),
        ]).observations[0]
        XCTAssertEqual(original, fork)
        let unrelated = F.parser([F.header(), F.message(time: F.milliseconds + 1)]).observations[0]
        XCTAssertNotEqual(original.operationID, unrelated.operationID)
    }

    func testOldOperationsAreFilteredAndSafetyLimitReported() {
        let parser = F.parser(
            [
                F.header(), F.message(id: "old", time: 1_600_000_000_000),
                F.message(), F.message(id: "second"),
            ], maxOperations: 1)
        XCTAssertEqual(parser.observations.count, 1)
        XCTAssertEqual(parser.issues, [.scanLimit])
    }
}
