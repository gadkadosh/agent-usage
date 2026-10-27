import Foundation
import SQLite3

/// OpenCode 2.x: response projections plus separately recorded title/compaction usage.
/// SQLite owns snapshot consistency; no transcript data crosses this reader.
actor OpenCodeHistorySource: HistoryAdapter {
    nonisolated let id = HistoryAgentID.openCode
    private let database: URL?
    private let limits: Limits

    struct Limits: Sendable {
        var maxRecords = 250_000
        var maxSteps = 20_000_000
    }

    init(database: URL?, limits: Limits = .init()) {
        self.database = database
        self.limits = limits
    }

    static func defaultDatabaseURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        func resolve(_ path: String, relativeTo base: URL) -> URL {
            if path == "~" { return home }
            if path.hasPrefix("~/") {
                return home.appendingPathComponent(String(path.dropFirst(2)))
            }
            return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }
        let data =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { resolve($0, relativeTo: home) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let root = data.appendingPathComponent("opencode", isDirectory: true)
        let name = environment["OPENCODE_DB"] ?? "opencode.db"
        return name == ":memory:" ? nil : resolve(name, relativeTo: root)
    }

    func read(_ request: HistoryRequest) throws -> HistoryAdapterResult {
        func result(_ state: HistoryCoverage.State, issues: Set<HistoryIssue> = [])
            -> HistoryAdapterResult
        {
            HistoryAdapterResult(
                observations: [],
                coverage: HistoryCoverage(state: state, hasReadings: false, issues: issues),
                fetchedAt: request.now
            )
        }
        guard let database else { return result(.missing) }
        do {
            // Stat afresh: URL resource values can cache an earlier file's existence.
            let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                FileManager.default.isReadableFile(atPath: database.path)
            else {
                throw HistoryReadError.unavailable
            }
        } catch CocoaError.fileReadNoSuchFile {
            return result(.missing)
        } catch {
            throw HistoryReadError.unavailable
        }
        do {
            let reader = try OpenCodeDatabase(database, maxSteps: limits.maxSteps)
            return try reader.read(request, maxRecords: max(0, limits.maxRecords))
        } catch OpenCodeDatabase.Failure.schema {
            return result(.unsupported, issues: [.unsupportedVersion])
        } catch OpenCodeDatabase.Failure.budget {
            return result(.partial, issues: [.scanLimit])
        } catch {
            throw HistoryReadError.unavailable
        }
    }
}

private final class OpenCodeDatabase {
    enum Failure: Error { case schema, unavailable, budget }
    private let db: OpaquePointer
    private let budget: Budget

    private final class Budget {
        var remaining: Int
        init(_ steps: Int) { remaining = max(0, steps / 1_000) }
    }

    init(_ url: URL, maxSteps: Int) throws {
        var connection: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK, let connection
        else {
            if let connection { sqlite3_close(connection) }
            throw Failure.unavailable
        }
        db = connection
        budget = Budget(maxSteps)
        sqlite3_busy_timeout(db, 250)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16 * 1_024 * 1_024)
        sqlite3_progress_handler(
            db,
            1_000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue()
                budget.remaining -= 1
                return budget.remaining < 0 ? 1 : 0
            },
            Unmanaged.passUnretained(budget).toOpaque()
        )
        try execute("PRAGMA query_only = ON")
        try execute("PRAGMA trusted_schema = OFF")
        try execute("PRAGMA cache_size = -2048")
        try execute("BEGIN")
    }

    deinit { sqlite3_close(db) }

    func read(_ request: HistoryRequest, maxRecords: Int) throws -> HistoryAdapterResult {
        for (table, required) in [
            ("session_v2", ["id", "fork_session_id", "time_created"]),
            ("session_message", ["id", "session_id", "type", "time_created", "data"]),
            ("event", ["id", "aggregate_id", "type", "created", "data"]),
        ] {
            var columns: Set<String> = []
            try rows("PRAGMA table_info(\(table))") { row in
                if let column = text(row, 1) { columns.insert(column) }
            }
            guard Set(required).isSubset(of: columns) else { throw Failure.schema }
        }

        var observations: [UsageObservation] = []
        var issues: Set<HistoryIssue> = []
        var records = 0
        var readable = false
        var total: Int64 = 0
        let since = request.since.timeIntervalSince1970 * 1_000
        let now = request.now.timeIntervalSince1970 * 1_000

        func accept(_ row: OpaquePointer, event: Bool) {
            records += 1
            guard records <= maxRecords else {
                issues.insert(.scanLimit)
                return
            }
            guard let id = text(row, 0), !id.isEmpty,
                sqlite3_column_type(row, 1) == SQLITE_INTEGER,
                sqlite3_column_int(row, 2) == 1
            else {
                issues.insert(.malformedRecord)
                return
            }
            // Fork projections use msg_<fork-event-id>_<sequence>, including reimported
            // forks whose session metadata no longer identifies them as forks. They are
            // copies, not spending, even after their original session is deleted.
            if !event, isForkCopy(id) { return }
            // An interrupted/failed assistant can legitimately have no usage yet.
            if !event, sqlite3_column_type(row, 4) == SQLITE_NULL {
                readable = true
                return
            }
            guard text(row, 4) == "object", let encoded = text(row, 3) else {
                issues.insert(.invalidUsage)
                return
            }
            guard let usage = try? JSONDecoder().decode(Tokens.self, from: Data(encoded.utf8)),
                let tokens = usage.total,
                !total.addingReportingOverflow(tokens).overflow
            else {
                issues.insert(.invalidUsage)
                return
            }
            readable = true
            total += tokens
            if tokens > 0 {
                observations.append(
                    UsageObservation(
                        operationID: "\(event ? "event" : "message"):\(id)",
                        timestamp: Date(
                            timeIntervalSince1970: Double(sqlite3_column_int64(row, 1)) / 1_000
                        ),
                        tokens: tokens
                    )
                )
            }
        }

        // Select usage only, never content. A transaction keeps both queries on one WAL
        // snapshot, including while OpenCode is writing or deleting a session.
        try rows(
            """
            SELECT m.id, m.time_created,
                CASE WHEN json_valid(m.data) THEN json_type(m.data) = 'object' ELSE 0 END,
                CASE WHEN json_valid(m.data) THEN json_extract(m.data, '$.tokens') END,
                CASE WHEN json_valid(m.data) THEN json_type(m.data, '$.tokens') END
            FROM session_message AS m JOIN session_v2 AS s ON s.id = m.session_id
            WHERE m.type = 'assistant'
                AND (m.time_created BETWEEN ? AND ? OR typeof(m.time_created) != 'integer')
                AND (s.fork_session_id IS NULL OR m.time_created >= s.time_created)
            LIMIT ?
            """,
            since: since,
            now: now,
            limit: maxRecords + 1
        ) { accept($0, event: false) }

        if records <= maxRecords {
            try rows(
                """
                SELECT e.id, e.created, json_valid(e.data),
                    CASE WHEN json_valid(e.data) THEN json_extract(e.data, '$.tokens') END,
                    CASE WHEN json_valid(e.data) THEN json_type(e.data, '$.tokens') END,
                    e.type,
                    CASE WHEN json_valid(e.data) THEN json_extract(e.data, '$.source') END
                FROM event AS e JOIN session_v2 AS s ON s.id = e.aggregate_id
                WHERE (e.type = 'session.usage.recorded' OR e.type GLOB 'session.usage.recorded.*')
                    AND (e.created BETWEEN ? AND ? OR typeof(e.created) != 'integer')
                LIMIT ?
                """,
                since: since,
                now: now,
                limit: maxRecords - records + 1
            ) { row in
                guard let type = text(row, 5),
                    type == "session.usage.recorded" || type == "session.usage.recorded.1"
                else {
                    records += 1
                    issues.insert(.unsupportedVersion)
                    return
                }
                guard let source = text(row, 6), source == "title" || source == "compaction" else {
                    records += 1
                    issues.insert(.unsupportedRecord)
                    return
                }
                accept(row, event: true)
            }
        }
        if records > maxRecords { issues.insert(.scanLimit) }
        try execute("COMMIT")
        // A genuinely empty, readable database measures zero. Invalid-only or permanently
        // bounded reads cannot erase an earlier accepted contribution with a guessed zero.
        let hasReadings = readable || issues.isEmpty
        return HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(
                state: issues.isEmpty ? .ready : .partial,
                hasReadings: hasReadings,
                issues: issues
            ),
            fetchedAt: request.now
        )
    }

    private func isForkCopy(_ id: String) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "msg" && !parts[1].isEmpty
            && !parts[2].isEmpty && parts[2].allSatisfy(\.isNumber)
    }

    private struct Tokens: Decodable {
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cache: Cache
        struct Cache: Decodable {
            let read: Int64
            let write: Int64
        }

        var total: Int64? {
            var sum: Int64 = 0
            for value in [input, output, reasoning, cache.read, cache.write] {
                guard value >= 0 else { return nil }
                let addition = sum.addingReportingOverflow(value)
                guard !addition.overflow else { return nil }
                sum = addition.partialValue
            }
            return sum
        }
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT,
            sqlite3_column_bytes(row, column) <= 16_384,
            let value = sqlite3_column_text(row, column)
        else { return nil }
        return String(cString: value)
    }

    private func execute(_ sql: String) throws { try rows(sql) { _ in } }

    private func rows(
        _ sql: String,
        since: Double? = nil,
        now: Double? = nil,
        limit: Int? = nil,
        consume: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw prepared == SQLITE_INTERRUPT ? Failure.budget : Failure.unavailable
        }
        defer { sqlite3_finalize(statement) }
        if let since { sqlite3_bind_double(statement, 1, since) }
        if let now { sqlite3_bind_double(statement, 2, now) }
        if let limit { sqlite3_bind_int64(statement, 3, Int64(limit)) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: consume(statement)
            case SQLITE_DONE: return
            case SQLITE_INTERRUPT: throw Failure.budget
            default: throw Failure.unavailable
            }
        }
    }
}
