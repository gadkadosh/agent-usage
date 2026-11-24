import Foundation
import XCTest

@testable import AgentUsage

// Invented records shaped like Claude Code 2.1.323 transcripts; never a real home directory.
@MainActor
final class ClaudeCodeHistorySourceTests: XCTestCase {
    private let now = HistoryFixtures.now
    private let calendar = HistoryFixtures.calendar

    func testDefaultAndCustomRoots() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        for (environment, expected) in [
            ([:], "/synthetic/home/.claude/projects"),
            (["CLAUDE_CONFIG_DIR": "~/claude"], "/synthetic/home/claude/projects"),
            (["CLAUDE_CONFIG_DIR": "/synthetic/claude"], "/synthetic/claude/projects"),
        ] {
            XCTAssertEqual(
                ClaudeCodeHistorySource.defaultRoot(home: home, environment: environment).path,
                expected
            )
        }
    }

    func testCountsEachResponseOnceIncludingSubagentsAndIgnoresEverythingElse() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(
            "-synthetic-project/session.jsonl",
            lines: [
                #"{"type":"user","timestamp":"2026-10-02T09:59:00.000Z","message":{"role":"user","content":"hi"}}"#,
                // One response, written once per content block with identical usage.
                assistant(id: "msg_a", at: "2026-10-02T10:00:02.000Z"),
                assistant(id: "msg_a", at: "2026-10-02T10:00:01.000Z"),
                assistant(id: "msg_a", at: "2026-10-02T10:00:03.000Z"),
                // A subagent's totals repeated in the parent are not additional usage.
                #"{"type":"user","timestamp":"2026-10-02T10:05:00.000Z","toolUseResult":{"usage":{"input_tokens":9000,"output_tokens":9000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
                #"{"type":"cost-state","sessionId":"s","totalCostUSD":12.5}"#,
                #"{"type":"some-future-record","usage":{"input_tokens":9000}}"#,
                #"{"type":"another-future-record","timestamp":1,"message":"text"}"#,
                assistant(id: "msg_old", at: "2026-08-01T10:00:00.000Z"),
            ]
        )
        try fixture.write(
            "-synthetic-project/session/subagents/agent-a.jsonl",
            lines: [assistant(id: "msg_sub", at: "2026-10-01T10:00:00Z")]
        )
        try fixture.write("-synthetic-project/session/subagents/agent-a.meta.json", lines: ["{}"])
        try fixture.write("-synthetic-project/session/tool-results/output.txt", lines: ["x"])
        try fixture.write("-synthetic-project/session/tool-results/output.jsonl", lines: ["x"])
        try fixture.write("-synthetic-project/memory/notes.md", lines: ["x"])
        try fixture.write("-synthetic-project/custom-title.json", lines: ["{}"])

        let source = ClaudeCodeHistorySource(root: fixture.root)
        let result = try await source.read(HistoryRequest(now: now, calendar: calendar))
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertEqual(result.coverage.issues, [])
        let byID = Dictionary(
            uniqueKeysWithValues: result.observations.map { ($0.operationID, $0) }
        )
        XCTAssertEqual(Set(byID.keys), ["msg_a", "msg_sub"])
        XCTAssertEqual(byID["msg_a"]?.tokens, 1_111)
        XCTAssertEqual(
            byID["msg_a"]?.timestamp,
            ISO8601DateFormatter().date(from: "2026-10-02T10:00:01Z")
        )
        XCTAssertNil(byID["msg_a"]?.costUSD)
        let snapshot = try await source.refresh(now: now, calendar: calendar)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 1_111)
        XCTAssertEqual(snapshot.summaries[.week]?.tokens, 2_222)
        XCTAssertEqual(snapshot.visibleSources.map(\.id.name), ["Claude Code"])
    }

    func testInvalidUsageAndMissingHistoryAreNotZeroReadings() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        let missing = ClaudeCodeHistorySource(root: fixture.root.appendingPathComponent("none"))
        let absent = try await missing.read(HistoryRequest(now: now, calendar: calendar))
        XCTAssertEqual(absent.coverage.state, .missing)

        try fixture.write(
            "-synthetic-project/session.jsonl",
            lines: [
                assistant(id: "msg_a", at: "2026-10-02T10:00:00.000Z"),
                #"{"type":"assistant","timestamp":"2026-10-02T10:01:00.000Z","message":{"id":"msg_b","usage":{"input_tokens":1}}}"#,
                assistant(id: "msg_c", at: "2026-10-02T10:02:00.000Z", input: -1),
                #"{"type":"assistant","#,
            ],
            ending: ""
        )
        let source = ClaudeCodeHistorySource(root: fixture.root)
        let result = try await source.read(HistoryRequest(now: now, calendar: calendar))
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(result.coverage.issues, [.invalidUsage, .incompleteLine])
        XCTAssertEqual(result.observations.map(\.tokens), [1_111])
    }

    func testConflictingCopiesAreExcluded() async throws {
        let fixture = try HistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write(
            "-synthetic-project/a.jsonl",
            lines: [assistant(id: "msg_a", at: "2026-10-02T10:00:00.000Z")]
        )
        try fixture.write(
            "-synthetic-project/b.jsonl",
            lines: [assistant(id: "msg_a", at: "2026-10-02T10:00:00.000Z", input: 2)]
        )
        let source = ClaudeCodeHistorySource(root: fixture.root)
        let result = try await source.read(HistoryRequest(now: now, calendar: calendar))
        XCTAssertEqual(result.observations, [])
        XCTAssertEqual(result.coverage.issues, [.conflictingOperation])
    }

    private func assistant(id: String, at timestamp: String, input: Int = 1) -> String {
        #"{"type":"assistant","uuid":"\#(UUID().uuidString)","requestId":"req_\#(id)","timestamp":"\#(timestamp)","isSidechain":false,"message":{"id":"\#(id)","model":"claude-synthetic","role":"assistant","content":[{"type":"text","text":"secret"}],"usage":{"input_tokens":\#(input),"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000},"output_tokens_details":{"reasoning_tokens":5},"iterations":[{"input_tokens":\#(input),"output_tokens":10}]}}}"#
    }
}
