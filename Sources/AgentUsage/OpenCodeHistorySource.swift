import Foundation
import SQLite3

/// Read-only adapter pinned to OpenCode v2.0.25:
/// https://github.com/anomalyco/opencode/tree/v2.0.25/packages/core/src/session
/// Contract: sql.ts/projector.ts and packages/schema/src/token-usage.ts.
/// Query only allowlisted usage metadata, never transcripts, events, credentials or session totals.
actor OpenCodeHistorySource {
    struct Limits: Sendable {
        var operations = 250_000
        var recordBytes = 8 * 1_024 * 1_024
        var querySeconds: TimeInterval = 5
    }

    private let database: URL?
    private let limits: Limits
    // Narrow IO hook for testing writes committed during a real SQLite read transaction.
    private let didReadRow: @Sendable () throws -> Void

    init(
        database: URL?,
        limits: Limits = Limits(),
        didReadRow: @escaping @Sendable () throws -> Void = {}
    ) {
        self.database = database
        self.limits = limits
        self.didReadRow = didReadRow
    }

    // v2.0.25 packages/cli/src/database-path.ts and packages/util/src/global-roots.ts.
    // Channel-specific databases and ephemeral :memory: histories are not auto-discovered.
    static func defaultDatabase(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let data =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let root = data.appendingPathComponent("opencode", isDirectory: true)
        let filename = environment["OPENCODE_DB"] ?? "opencode.db"
        if filename == ":memory:" { return nil }
        return filename.hasPrefix("/")
            ? URL(fileURLWithPath: filename) : root.appendingPathComponent(filename)
    }

    func refresh(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws
        -> HistorySnapshot
    {
        guard var database else {
            return snapshot([], state: .missing, now: now, calendar: calendar)
        }
        // URL resource values are cached; a deleted/replaced database must be rediscovered.
        database.removeAllCachedResourceValues()
        do {
            let values = try database.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                FileManager.default.isReadableFile(atPath: database.path)
            else {
                throw HistoryReadError.unavailable
            }
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            return snapshot([], state: .missing, now: now, calendar: calendar)
        } catch {
            throw HistoryReadError.unavailable
        }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw HistoryReadError.unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 250)
        // Bound work inside SQLite too, including malformed/large archives and ancestry queries.
        let deadline = Deadline(after: limits.querySeconds)
        sqlite3_progress_handler(
            connection,
            1_000,
            { context in
                guard let context else { return 1 }
                return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
            },
            Unmanaged.passUnretained(deadline).toOpaque()
        )
        defer { sqlite3_progress_handler(connection, 0, nil, nil) }
        try execute("BEGIN", on: connection)
        defer { try? execute("ROLLBACK", on: connection) }

        // Probe the v2 contract separately: a missing/older schema is unsupported, not zero.
        guard
            let probe = try? prepare(
                """
                SELECT m.id, m.session_id, m.seq, m.type, m.time_created, m.data,
                       s.fork_session_id FROM session_message m JOIN session_v2 s ON s.id = m.session_id LIMIT 0
                """,
                on: connection
            )
        else {
            guard sqlite3_errcode(connection) == SQLITE_ERROR else {
                throw HistoryReadError.unavailable
            }
            return snapshot(
                [],
                state: .unsupported,
                issues: [.unsupportedVersion],
                now: now,
                calendar: calendar
            )
        }
        sqlite3_finalize(probe)
        let since = HistoryPeriod.month.start(at: now, calendar: calendar)
        let query = try prepare(
            """
            SELECT m.id, m.session_id, m.seq,
                CASE WHEN length(CAST(m.data AS BLOB)) > ? THEN NULL
                WHEN json_valid(m.data) THEN json_object(
                    'timestamp', json_extract(m.data, '$.time.created'),
                    'input', json_extract(m.data, '$.tokens.input'),
                    'output', json_extract(m.data, '$.tokens.output'),
                    'reasoning', json_extract(m.data, '$.tokens.reasoning'),
                    'cacheRead', json_extract(m.data, '$.tokens.cache.read'),
                    'cacheWrite', json_extract(m.data, '$.tokens.cache.write'),
                    'hasTokens', json_type(m.data, '$.tokens') IS NOT NULL)
                ELSE NULL END
            FROM session_message m JOIN session_v2 s ON s.id = m.session_id
            WHERE m.time_created >= ? AND m.time_created <= ? AND m.type IN ('assistant', 'compaction')
            ORDER BY m.time_created, m.id LIMIT ?
            """,
            on: connection
        )
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(limits.recordBytes))
        sqlite3_bind_double(query, 2, since.timeIntervalSince1970 * 1_000)
        sqlite3_bind_double(query, 3, now.timeIntervalSince1970 * 1_000)
        sqlite3_bind_int64(query, 4, Int64(limits.operations) + 1)
        var canonical: [String: UsageObservation] = [:]
        var conflicting: Set<String> = []
        var issues: Set<HistoryIssue> = []
        var visited = 0
        let decoder = JSONDecoder()
        while true {
            guard !deadline.expired else { throw HistoryReadError.unavailable }
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryReadError.unavailable }
            visited += 1
            guard visited <= limits.operations else {
                issues.insert(.scanLimit)
                break
            }
            guard let id = text(query, 0), let session = text(query, 1),
                !id.isEmpty, !session.isEmpty, id.utf8.count <= 256, session.utf8.count <= 256,
                let payload = text(query, 3), payload.utf8.count <= 4_096,
                let usage = try? decoder.decode(Usage.self, from: Data(payload.utf8))
            else {
                issues.insert(.malformedRecord)
                continue
            }
            // Usage is optional on unfinished requests and on failures without measured usage.
            guard usage.hasTokens != 0 else { continue }
            guard let total = usage.total, let milliseconds = usage.timestamp,
                milliseconds.isFinite, milliseconds >= 0, milliseconds < 32_503_680_000_000
            else {
                issues.insert(.invalidUsage)
                continue
            }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            guard timestamp >= since, timestamp <= now else {
                issues.insert(.invalidUsage)
                continue
            }
            let seq = sqlite3_column_int64(query, 2)
            let key = try identity(
                id: id,
                session: session,
                seq: seq,
                on: connection,
                issues: &issues
            )
            let observation = UsageObservation(
                operationID: key,
                timestamp: timestamp,
                tokens: total
            )
            try didReadRow()
            if let previous = canonical[key], previous != observation {
                conflicting.insert(key)
                issues.insert(.conflictingOperation)
            } else {
                canonical[key] = observation
            }
        }
        for key in conflicting { canonical.removeValue(forKey: key) }
        return snapshot(
            Array(canonical.values),
            state: issues.isEmpty ? .ready : .partial,
            issues: issues,
            now: now,
            calendar: calendar
        )
    }

    /// projectFork preserves seq/data but assigns msg_<fork-event>_<seq> IDs.
    /// Follow only those copied rows, not new work or subagent parent_id relationships.
    /// A deleted origin still gives sibling copies the same (session, seq) identity.
    private func identity(
        id: String,
        session: String,
        seq: Int64,
        on db: OpaquePointer,
        issues: inout Set<HistoryIssue>
    ) throws -> String {
        var id = id
        var session = session
        var seen: Set<String> = []
        while id.hasPrefix("msg_"), id.hasSuffix("_\(seq)") {
            guard seen.count < 64, seen.insert(session).inserted else {
                throw HistoryReadError.unavailable
            }
            let query = try prepare(
                """
                SELECT s.fork_session_id, p.id FROM session_v2 s
                LEFT JOIN session_message p ON p.session_id = s.fork_session_id AND p.seq = ?
                WHERE s.id = ?
                """,
                on: db
            )
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int64(query, 1, seq)
            _ = session.withCString {
                sqlite3_bind_text(
                    query,
                    2,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            let status = sqlite3_step(query)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw HistoryReadError.unavailable
            }
            guard status == SQLITE_ROW, let parent = text(query, 0) else { break }
            session = parent
            guard let parentID = text(query, 1) else {
                // A removed intermediate ancestor can hide an earlier origin. Retain the
                // surviving copy, but do not claim complete deduplication of that lineage.
                issues.insert(.unresolvedFork)
                break
            }
            id = parentID
        }
        return "opencode:\(session):\(seq)"
    }

    private func prepare(_ sql: String, on db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw HistoryReadError.unavailable
        }
        return statement
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryReadError.unavailable
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func snapshot(
        _ observations: [UsageObservation],
        state: HistoryCoverage.State,
        issues: Set<HistoryIssue> = [],
        now: Date,
        calendar: Calendar
    ) -> HistorySnapshot {
        HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            observations,
                            period: $0,
                            now: now,
                            calendar: calendar
                        )
                    )
                }
            ),
            coverage: HistoryCoverage(
                state: state,
                filesRead: state == .ready || state == .partial ? 1 : 0,
                issues: issues
            ),
            fetchedAt: now
        )
    }

    private struct Usage: Decodable {
        let timestamp: Double?
        let input: Int64?
        let output: Int64?
        let reasoning: Int64?
        let cacheRead: Int64?
        let cacheWrite: Int64?
        let hasTokens: Int

        var total: Int64? {
            guard let input, let output, let reasoning, let cacheRead, let cacheWrite else {
                return nil
            }
            let values = [input, output, reasoning, cacheRead, cacheWrite]
            guard values.allSatisfy({ (0...1_000_000_000).contains($0) }) else { return nil }
            return values.reduce(0, +)
        }
    }

    private final class Deadline {
        let end: TimeInterval
        init(after seconds: TimeInterval) { end = ProcessInfo.processInfo.systemUptime + seconds }
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= end }
    }
}
