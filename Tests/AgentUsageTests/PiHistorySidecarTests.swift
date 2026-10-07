import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class PiHistorySidecarTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testLeaseSidecarsAreIgnoredInFlatAndProjectRoots() async throws {
        for path in ["session.jsonl", "--synthetic--/session.jsonl"] {
            let fixture = try PiHistoryFixtureRoot()
            defer { fixture.remove() }
            try fixture.write(path, lines: [F.header(), F.message()])
            let sidecar = try fixture.write(path + ".lease", lines: ["not a session"])
            let before = try Data(contentsOf: sidecar)
            let source = PiHistorySource(root: fixture.root)

            for _ in 0..<2 {
                let snapshot = try await source.refresh(now: F.now, calendar: F.calendar)
                XCTAssertEqual(snapshot.coverage.state, .ready)
                XCTAssertEqual(snapshot.coverage.filesRead, 1)
                XCTAssertTrue(snapshot.coverage.issues.isEmpty)
                XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
            }
            let parsed = await source.filesParsed
            XCTAssertEqual(parsed, 1)
            XCTAssertEqual(try Data(contentsOf: sidecar), before)
        }
    }

    func testOrphanLeaseSidecarIsNotReportedAsUnavailableHistory() async throws {
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        try fixture.write("orphan.jsonl.lease", lines: ["not a session"])
        let snapshot = try await PiHistorySource(root: fixture.root).refresh(
            now: F.now, calendar: F.calendar)
        XCTAssertEqual(snapshot.coverage.state, .missing)
        XCTAssertEqual(snapshot.coverage.filesRead, 0)
        XCTAssertTrue(snapshot.coverage.issues.isEmpty)
    }

    func testOtherUnsupportedFilesStillProduceCoverageWarnings() async throws {
        for path in ["archive.jsonl.gz", "unknown.lease"] {
            let fixture = try PiHistoryFixtureRoot()
            defer { fixture.remove() }
            try fixture.write(lines: [F.header(), F.message()])
            try fixture.write(path, lines: ["not a supported history"])
            let snapshot = try await PiHistorySource(root: fixture.root).refresh(
                now: F.now, calendar: F.calendar)
            XCTAssertEqual(snapshot.coverage.state, .partial)
            XCTAssertEqual(snapshot.coverage.filesRead, 1)
            XCTAssertEqual(snapshot.coverage.issues, [.unsupportedRecord])
            XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        }
    }
}
