import CSQLite
import Foundation

/// Synthetic v2.0.25 table/record subsets. No real agent histories or credentials.
final class OpenCodeHistoryFixture {
    let root: URL
    let database: URL
    private var connection: OpaquePointer?

    init(schema: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = root.appendingPathComponent("opencode.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw FixtureError() }
        if schema {
            try execute(
                """
                CREATE TABLE session_v2 (id TEXT PRIMARY KEY, fork_session_id TEXT, parent_id TEXT, time_created INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE session_message (
                  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
                CREATE INDEX session_message_time_created_idx ON session_message(time_created);
                INSERT INTO session_v2(id) VALUES ('synthetic');
                """
            )
        }
    }

    func remove() {
        if let connection { sqlite3_close(connection) }
        connection = nil
        try? FileManager.default.removeItem(at: root)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError()
        }
    }

    func write(
        id: String = "operation",
        type: String = "assistant",
        date: Date = PiHistoryFixtures.now,
        tokens: [String: Any]? = OpenCodeHistoryFixture.tokens,
        extra: [String: Any] = [:],
        session: String = "synthetic"
    ) throws {
        var record = extra
        record["time"] = ["created": Int64(date.timeIntervalSince1970 * 1_000)]
        if let tokens { record["tokens"] = tokens }
        try writeRaw(
            id: id,
            type: type,
            date: date,
            data: String(decoding: JSONSerialization.data(withJSONObject: record), as: UTF8.self),
            session: session
        )
    }

    func writeRaw(id: String, type: String, date: Date, data: String, session: String = "synthetic")
        throws
    {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                connection,
                "INSERT OR REPLACE INTO session_message VALUES (?, ?, ?, 0, ?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { throw FixtureError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, session, -1, transient)
        sqlite3_bind_text(statement, 3, type, -1, transient)
        let time = Int64(date.timeIntervalSince1970 * 1_000)
        sqlite3_bind_int64(statement, 4, time)
        sqlite3_bind_int64(statement, 5, time)
        sqlite3_bind_text(statement, 6, data, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError() }
    }

    static var tokens: [String: Any] {
        ["input": 100, "output": 20, "reasoning": 10, "cache": ["read": 30, "write": 40]]
    }
    private struct FixtureError: Error {}
}
