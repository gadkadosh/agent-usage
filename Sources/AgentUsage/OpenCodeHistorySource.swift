import CSQLite
import Darwin
import Foundation

/// Read-only SQLite adapter. Each refresh uses a consistent transaction, including live WAL data.
/// Forks materialize history with new IDs. Match OpenCode stats.ts by excluding pre-fork copies.
actor OpenCodeHistorySource {
    struct Limits: Sendable {
        var operations = 250_000
        var recordBytes = 8 * 1_024 * 1_024
        var refreshBytes = 256 * 1_024 * 1_024
        var sqliteSteps: Int32 = 5_000_000
    }

    private let database: URL
    private let limits: Limits

    init(database: URL, limits: Limits = Limits()) {
        self.database = database.standardizedFileURL
        self.limits = limits
    }

    /// OpenCode's global-roots.ts and cli/database-path.ts use XDG even on macOS.
    /// The stable release database is opencode.db. Custom channels need OPENCODE_DB.
    static func defaultDatabase(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let data =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let root = data.appendingPathComponent("opencode", isDirectory: true)
        guard let override = environment["OPENCODE_DB"], !override.isEmpty else {
            return root.appendingPathComponent("opencode.db")
        }
        // OpenCode resolves relative OPENCODE_DB values against its data directory, not cwd.
        return override.hasPrefix("/")
            ? URL(fileURLWithPath: override)
            : root.appendingPathComponent(override)
    }

    func read(_ context: HistoryReadContext) throws -> HistoryReadings {
        var info = stat()
        guard lstat(database.path, &info) == 0 else {
            guard errno == ENOENT else { throw HistoryReadError.unavailable }
            let legacy = database.deletingLastPathComponent().appendingPathComponent("storage")
            return empty(
                FileManager.default.fileExists(atPath: legacy.path) ? .unsupported : .missing
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG,
            FileManager.default.isReadableFile(atPath: database.path)
        else { throw HistoryReadError.unavailable }
        for suffix in ["-wal", "-shm", "-journal"] {
            var sidecar = stat()
            if lstat(database.path + suffix, &sidecar) == 0 {
                guard sidecar.st_mode & S_IFMT == S_IFREG else {
                    throw HistoryReadError.unavailable
                }
            } else if errno != ENOENT {
                throw HistoryReadError.unavailable
            }
        }
        // Foundation can normalize /private/var back to /var even after resolving links.
        // SQLite NOFOLLOW rejects linked parent components too, so use POSIX realpath on
        // the explicitly selected directory, without resolving the database leaf.
        guard let directory = realpath(database.deletingLastPathComponent().path, nil) else {
            throw HistoryReadError.unavailable
        }
        defer { free(directory) }
        let path = String(cString: directory) + "/" + database.lastPathComponent
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw HistoryReadError.unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 250)
        // Bound SQLite's own row buffers too, not just the metadata returned to Swift.
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 16 * 1_024 * 1_024)
        // Bound scanning work, including corrupt or unexpectedly unindexed databases.
        sqlite3_progress_handler(connection, max(1, limits.sqliteSteps), { _ in 1 }, nil)
        try execute(connection, "PRAGMA query_only = ON")
        try execute(connection, "PRAGMA trusted_schema = OFF")
        try execute(connection, "BEGIN")
        defer { try? execute(connection, "ROLLBACK") }
        guard
            try columns(connection, table: "session_message").isSuperset(of: [
                "id", "session_id", "type", "seq", "time_created", "time_updated", "data",
            ]),
            try columns(connection, table: "session_v2").isSuperset(of: [
                "id", "fork_session_id", "time_created",
            ])
        else {
            return empty(.unsupported)
        }
        var parser = OpenCodeHistoryParser()
        var scanned = 0
        // Project scalar allowlisted metadata. Large records and invalid JSON are reported,
        // but their contents never reach Swift. Numeric checks also reject strings/objects.
        let fields = [
            "input": "$.tokens.input", "output": "$.tokens.output",
            "reasoning": "$.tokens.reasoning", "cacheRead": "$.tokens.cache.read",
            "cacheWrite": "$.tokens.cache.write",
        ].sorted { $0.key < $1.key }.map { key, path in
            "'\(key)', \(number(path))"
        }.joined(separator: ", ")
        let query = """
            SELECT message.id, message.type, message.time_created,
              length(CAST(data AS BLOB)),
              CASE WHEN length(CAST(data AS BLOB)) <= ? AND json_valid(data) THEN
                json_object('hasTokens', json(CASE WHEN json_type(data, '$.tokens') IS NULL THEN 'false' ELSE 'true' END),
                  'created', \(number("$.time.created")),
                  'tokens', json_object(\(fields)))
              END
            FROM session_message AS message
            JOIN session_v2 AS session ON session.id = message.session_id
            WHERE message.time_created >= ?
              AND (session.fork_session_id IS NULL OR message.time_created >= session.time_created)
            ORDER BY message.time_created, message.id
            LIMIT ?
            """
        let statement = try prepare(connection, query)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limits.recordBytes))
        sqlite3_bind_double(statement, 2, context.since.timeIntervalSince1970 * 1_000)
        sqlite3_bind_int64(statement, 3, Int64(limits.operations) + 1)
        var remainingBytes = Int64(limits.refreshBytes)
        var issues: Set<HistoryIssue> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            if step == SQLITE_INTERRUPT {
                issues.insert(.scanLimit)
                break
            }
            guard step == SQLITE_ROW else { throw HistoryReadError.unavailable }
            guard scanned < limits.operations else {
                issues.insert(.scanLimit)
                break
            }
            scanned += 1
            let bytes = sqlite3_column_int64(statement, 3)
            guard bytes >= 0, bytes <= remainingBytes else {
                issues.insert(.scanLimit)
                break
            }
            remainingBytes -= bytes
            if bytes > limits.recordBytes {
                issues.insert(.oversizedRecord)
                continue
            }
            guard let metadata = sqlite3_column_text(statement, 4),
                let id = text(statement, 0), let type = text(statement, 1),
                [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 2))
            else {
                issues.insert(.malformedRecord)
                continue
            }
            parser.consume(
                id: id,
                type: type,
                created: sqlite3_column_double(statement, 2),
                metadata: Data(bytes: metadata, count: Int(sqlite3_column_bytes(statement, 4)))
            )
        }
        issues.formUnion(parser.issues)
        let canonical = UsageObservation.resolve(parser.observations)
        if canonical.hasConflicts { issues.insert(.conflictingOperation) }
        // One validated database is readable even when the chosen period has no operations.
        return HistoryReadings(
            observations: canonical.observations,
            coverage: HistoryCoverage(
                state: issues.isEmpty ? .ready : .partial,
                filesRead: 1,
                issues: issues
            )
        )
    }

    private func empty(_ state: HistoryCoverage.State) -> HistoryReadings {
        HistoryReadings(
            observations: [],
            coverage: HistoryCoverage(state: state, filesRead: 0, issues: [])
        )
    }

    private func number(_ path: String) -> String {
        "CASE WHEN json_type(data, '\(path)') IN ('integer', 'real') THEN json_extract(data, '\(path)') END"
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
            sqlite3_column_bytes(statement, column) <= 256,
            let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private func columns(_ connection: OpaquePointer, table: String) throws -> Set<String> {
        let statement = try prepare(connection, "PRAGMA table_info('\(table)')")
        defer { sqlite3_finalize(statement) }
        var result: Set<String> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw HistoryReadError.unavailable }
            if let column = text(statement, 1) { result.insert(column) }
        }
    }

    private func prepare(_ connection: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw HistoryReadError.unavailable
        }
        return statement
    }

    private func execute(_ connection: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryReadError.unavailable
        }
    }
}
