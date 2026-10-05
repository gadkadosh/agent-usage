import Darwin
import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class PiHistoryMemoryTests: XCTestCase {
    /// Run alone in a fresh test process: allocator reuse in a full suite can hide regressions.
    /// AGENT_USAGE_MEMORY_REGRESSION=1 swift test --filter PiHistoryMemoryTests
    func testReadBuffersDoNotAccumulateAcrossA64MiBFile() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_USAGE_MEMORY_REGRESSION"] == "1" else {
            throw XCTSkip("Opt-in memory regression; run with --filter PiHistoryMemoryTests.")
        }
        let fixture = try PiHistoryFixtureRoot()
        defer { fixture.remove() }
        let file = try fixture.write(lines: [
            PiHistoryFixtures.header(), PiHistoryFixtures.message(),
        ])
        // Generate by repeatedly writing the same 32 KiB record, not a 64 MiB in-memory fixture.
        let shell = #"{"type":"custom","data":""}"#
        let padding = String(repeating: "x", count: 32 * 1_024 - shell.utf8.count - 1)
        let record = Data(("{\"type\":\"custom\",\"data\":\"\(padding)\"}\n").utf8)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        defer { try? writer.close() }
        for _ in 0..<2_048 {
            try autoreleasepool { try writer.write(contentsOf: record) }
        }
        try writer.close()

        let baseline = try physicalFootprint()
        let source = PiHistorySource(
            root: fixture.root,
            didReadFile: {
                // Inspect before the source returns/yields: an outer pool must not hide buildup.
                let growth = try physicalFootprint() - baseline
                print("MEMORY REGRESSION: extra footprint at read completion = \(growth) bytes")
                XCTAssertLessThan(
                    growth, 24 * 1_024 * 1_024,
                    "A 64 MiB transcript-only payload must not accumulate as retained read buffers."
                )
            })
        let snapshot = try await source.refresh(
            now: PiHistoryFixtures.now, calendar: PiHistoryFixtures.calendar)
        XCTAssertEqual(snapshot.coverage.state, .ready)
        XCTAssertEqual(snapshot.coverage.filesRead, 1)
        XCTAssertEqual(snapshot.summaries[.today]?.tokens, 190)
        XCTAssertTrue(snapshot.coverage.issues.isEmpty)
    }
}

/// Whole-process footprint, not exact index size. Used only by the isolated opt-in regression.
private func physicalFootprint() throws -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw HistoryReadError.unavailable }
    return Int64(info.phys_footprint)
}
