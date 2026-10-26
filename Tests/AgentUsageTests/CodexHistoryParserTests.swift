import Foundation
import XCTest

@testable import AgentUsage

final class CodexHistoryParserTests: XCTestCase {
    private typealias F = CodexHistoryFixtures

    func testLegacyCountersCountActivityOnceIncludingCacheAndReasoningSubsets() {
        let parser = F.parse([
            F.header(), F.start(), F.counter(), F.counter(),
            F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 60])
        XCTAssertEqual(parser.issues, [])
    }

    func testDurableRecordsSuppressOnlyTheirPairedFallbackInTheSameTurn() {
        let parser = F.parse([
            F.header(), F.start("old"), F.counter(),
            F.start(), F.durable(input: 50, output: 10),
            F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens).sorted(), [60, 120])
        XCTAssertEqual(parser.observations.count, 2)
    }

    func testCopiedForkPrefixAndNestedParentSettingsAreExcludedButChildSpendingCounts() {
        let parser = F.parse([
            F.header("child", fork: "thread-a"), F.header(),
            F.settings("thread-a"), F.start(), F.counter(), F.durable(),
            F.settings("child"), F.start("child-turn"),
            F.durable("child-response", thread: "child", turn: "child-turn", input: 50, output: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [60])
    }

    func testIncompleteResponseAfterDurableResponseInSameTurnStillCounts() {
        let parser = F.parse([
            F.header(), F.start(), F.durable(), F.counter(),
            F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 60])
        XCTAssertEqual(parser.issues, [])
    }

    func testReferencedForkUsesLastOperationNotInheritedCumulativeTotal() {
        let parser = F.parse([
            F.header("child", fork: "thread-a"), F.settings("child"),
            F.start("child-turn"), F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [60])
        XCTAssertTrue(parser.issues.contains(.unsupportedRecord))
    }

    func testResumeReplayWithoutActiveTurnDoesNotCreateSpending() {
        let parser = F.parse([
            F.header(), F.start(), F.counter(),
            F.line("event_msg", ["type": "task_complete", "turn_id": "turn-a"]),
            F.counter(), F.start("resumed"), F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 60])
    }

    func testCounterResetIsNotSpendingAndLaterConsistentReportsRecover() {
        let parser = F.parse([
            F.header(), F.start(), F.counter(), F.counter(10, 2),
            F.counter(20, 4, lastInput: 10, lastOutput: 2),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 12])
        XCTAssertTrue(parser.issues.contains(.invalidUsage))
    }

    func testInvalidUsageUnsupportedHeaderLimitsAndPartialLinesAreReported() {
        XCTAssertFalse(F.parse([F.start(), F.counter()]).isSupported)
        let invalid = F.line(
            "token_usage_record",
            [
                "thread_id": "thread-a", "turn_id": "turn-a", "response_id": "r",
                "usage": F.tokens(-1, 5),
            ]
        )
        XCTAssertTrue(F.parse([F.header(), invalid]).issues.contains(.invalidUsage))
        let limited = F.parse([F.header(), F.durable(), F.durable("other")], max: 1)
        XCTAssertEqual(limited.observations.count, 1)
        XCTAssertTrue(limited.issues.contains(.scanLimit))
        var partial = F.parse([F.header()])
        partial.consume(Data("{\"type\":".utf8), terminated: false)
        XCTAssertTrue(partial.issues.contains(.incompleteLine))
    }

    func testWorldStateSnapshotsAndPatchesDoNotAffectAccountingOrCoverage() {
        let parser = F.parse([
            F.header(),
            F.line("world_state", ["full": true, "state": ["cwd": "/invented"]]),
            F.start(), F.durable(),
            F.line("world_state", ["full": false, "state": ["cwd": "/invented/child"]]),
            F.counter(), F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120, 60])
        XCTAssertEqual(parser.issues, [])
    }

    func testLocalSettingsDoNotEndTheActiveTurnOrBreakCounterPairing() {
        for durable in [true, false] {
            var lines = [F.header(), F.start(), F.settings("thread-a")]
            if durable { lines.append(F.durable()) }
            lines += [F.counter(), F.counter(150, 30, lastInput: 50, lastOutput: 10)]
            let parser = F.parse(lines)
            XCTAssertEqual(parser.observations.map(\.tokens), [120, 60])
            XCTAssertEqual(parser.issues, [])
        }
    }

    func testChildSettingsDoNotCarryAnInheritedTurnIntoLocalCounterAccounting() {
        let parser = F.parse([
            F.header("child", fork: "thread-a"), F.header(), F.start(), F.counter(),
            F.settings("child"), F.counter(150, 30, lastInput: 50, lastOutput: 10),
        ])
        XCTAssertEqual(parser.observations, [])
        XCTAssertEqual(parser.issues, [.unsupportedRecord])
    }

    func testUnknownRolloutRecordsStillReportIncompleteCoverage() {
        let parser = F.parse([
            F.header(), F.line("unknown_record", [:]), F.durable(),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120])
        XCTAssertEqual(parser.issues, [.unsupportedRecord])
    }

    func testNonUsagePayloadsAndCompactionSnapshotsAreNotAdditionalSpending() {
        let parser = F.parse([
            F.header(), F.line("response_item", ["type": "message", "content": "invented"]),
            F.line("compacted", ["latest_token_usage_record": ["usage": F.tokens(500, 10)]]),
            F.line("event_msg", ["type": "token_count", "info": NSNull()]), F.durable(),
        ])
        XCTAssertEqual(parser.observations.map(\.tokens), [120])
        XCTAssertEqual(parser.issues, [])
    }
}
