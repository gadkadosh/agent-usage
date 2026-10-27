import Foundation
import XCTest

@testable import AgentUsage

/// Opt-in, generated histories only. No existing directories, credentials or network access.
@MainActor
final class PiHistoryBenchmarkTests: XCTestCase {
    private typealias F = PiHistoryFixtures

    func testLargeSyntheticColdCatchUpWarmAndAppendScans() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_USAGE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set AGENT_USAGE_BENCHMARK=1 to generate and scan large synthetic roots.")
        }
        // Both exceed the default 256 MiB refresh budget; neither hits the operation/file limits.
        for (name, files, operationsPerFile, lineBytes) in [
            ("transcript-heavy", 40, 256, 32_768),
            ("operation-heavy", 160, 1_024, 2_048),
        ] {
            let fixture = try HistoryFixtureRoot()
            defer { fixture.remove() }
            var bytes = 0
            var firstFile: URL?
            for fileIndex in 0..<files {
                var lines = [F.header(id: "session-\(fileIndex)")]
                for operation in 0..<operationsPerFile {
                    let id = "operation-\(fileIndex)-\(operation)"
                    let empty = F.message(id: id, extra: ",\"content\":\"\"")
                    let padding = String(repeating: "x", count: lineBytes - empty.utf8.count - 1)
                    lines.append(F.message(id: id, extra: ",\"content\":\"\(padding)\""))
                }
                let file = try fixture.write(
                    "project-\(fileIndex % 20)/session-\(fileIndex).jsonl",
                    lines: lines
                )
                if firstFile == nil { firstFile = file }
                bytes += (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize!
            }
            print(
                "BENCHMARK \(name): bytes=\(bytes), files=\(files), operations=\(files * operationsPerFile)"
            )
            let source = PiHistorySource(root: fixture.root)
            let service = HistoryService(adapters: [source])
            let cold = try await scan(
                service,
                source: source,
                label: "\(name) cold + catch-up",
                expectCatchUp: true
            )
            let total = Int64(files * operationsPerFile * 190)
            XCTAssertFalse(cold.hasMore)
            XCTAssertEqual(cold.coverage.state, .ready)
            let coldFilesRead = await source.filesRead
            XCTAssertEqual(coldFilesRead, files)
            XCTAssertEqual(cold.summaries[.today]?.tokens, total)
            var parsed = await source.filesParsed
            XCTAssertEqual(parsed, files, "Catch-up must not reread cached files.")

            for iteration in 1...3 {
                let warm = try await scan(
                    service,
                    source: source,
                    label: "\(name) warm-\(iteration)"
                )
                XCTAssertEqual(warm.summaries[.today]?.tokens, total)
                XCTAssertEqual(warm.coverage.state, .ready)
            }
            parsed = await source.filesParsed
            XCTAssertEqual(parsed, files, "Warm scans must not read history content.")

            let handle = try FileHandle(forWritingTo: firstFile!)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((F.message(id: "appended") + "\n").utf8))
            try handle.close()
            let appended = try await scan(service, source: source, label: "\(name) append")
            XCTAssertEqual(appended.coverage.state, .ready)
            XCTAssertEqual(appended.summaries[.today]?.tokens, total + 190)
            parsed = await source.filesParsed
            XCTAssertEqual(parsed, files + 1, "Only the appended file should be reparsed.")
        }
    }

    /// Sample the main actor while the source actor works. Timings are evidence, not CI thresholds.
    private func scan(
        _ service: HistoryService,
        source: PiHistorySource,
        label: String,
        expectCatchUp: Bool = false
    ) async throws -> HistorySnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        var lastTick = start
        var ticks = 0
        var longestGap = Duration.zero
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = clock.now
                longestGap = max(longestGap, lastTick.duration(to: now))
                lastTick = now
                ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        let publications = HistorySnapshotRecorder()
        let snapshot = try await service.refresh(now: F.now, calendar: F.calendar) {
            await publications.append($0)
        }
        let updates = await publications.values
        if expectCatchUp {
            XCTAssertTrue(updates.contains { $0.hasMore })
            XCTAssertLessThan(
                updates.first?.summaries[.today]?.tokens ?? 0,
                snapshot.summaries[.today]?.tokens ?? 0
            )
        }
        XCTAssertEqual(updates.last?.summaries, snapshot.summaries)
        let elapsed = start.duration(to: clock.now)
        longestGap = max(longestGap, lastTick.duration(to: clock.now))
        heartbeat.cancel()
        await heartbeat.value
        let parsed = await source.filesParsed
        print(
            "BENCHMARK \(label): seconds=\(seconds(elapsed)), parsed=\(parsed), publications=\(updates.count), mainTicks=\(ticks), maxMainGapMs=\(seconds(longestGap) * 1_000)"
        )
        return snapshot
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
