import Foundation
import SQLite3

@testable import AgentUsage

/// Minimal v2 tables with the upstream primary keys and usage fields. All data is invented.
final class OpenCodeHistoryFixture {
    let root: HistoryFixtureRoot
    let database: URL
    private let connection: OpaquePointer
    static let usage = tokens()

    init() throws {
        root = try HistoryFixtureRoot()
        database = root.root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            throw HistoryReadError.unavailable
        }
        connection = db
        try execute(
            """
            PRAGMA journal_mode = WAL;
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, parent_id TEXT, fork_session_id TEXT,
                time_created INTEGER NOT NULL,
                tokens_input INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
                seq INTEGER NOT NULL DEFAULT 0, time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL
            );
            CREATE INDEX session_message_time_created_idx ON session_message(time_created);
            CREATE TABLE event (
                id TEXT PRIMARY KEY, aggregate_id TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0,
                created INTEGER NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL
            );
            CREATE INDEX event_aggregate_type_seq_idx ON event(aggregate_id, type, seq);
            CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT);
            """
        )
        try session()
    }

    deinit {
        sqlite3_close(connection)
        root.remove()
    }

    static func tokens(
        input: Int64 = 100,
        output: Int64 = 20,
        reasoning: Int64 = 10,
        read: Int64 = 30,
        write: Int64 = 40
    ) -> String {
        """
        {"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(read),"write":\(write)}}
        """
    }

    func session(
        _ id: String = "session",
        parent: String? = nil,
        fork: String? = nil,
        at date: Date = HistoryFixtures.now
    ) throws {
        try execute(
            """
            INSERT INTO session_v2(id, parent_id, fork_session_id, time_created)
            VALUES (\(quote(id)), \(parent.map(quote) ?? "NULL"), \(fork.map(quote) ?? "NULL"), \(millis(date)));
            """
        )
    }

    func message(
        _ id: String = "msg_response",
        session: String = "session",
        at date: Date = HistoryFixtures.now,
        usage: String? = usage,
        type: String = "assistant"
    ) throws {
        let data =
            "{\(usage.map { "\"tokens\":\($0)," } ?? "")\"content\":[{\"type\":\"text\",\"text\":\"SYNTHETIC TRANSCRIPT MUST NOT ESCAPE\"}]}"
        try execute(
            """
            INSERT INTO session_message(id, session_id, type, time_created, data)
            VALUES (\(quote(id)), \(quote(session)), \(quote(type)), \(millis(date)), \(quote(data)));
            """
        )
    }

    func event(
        _ id: String = "evt_usage",
        session: String = "session",
        source: String = "title",
        type: String = "session.usage.recorded.1",
        at date: Date = HistoryFixtures.now,
        usage: String = usage
    ) throws {
        let data =
            "{\"sessionID\":\(quoteJSON(session)),\"source\":\(quoteJSON(source)),\"tokens\":\(usage)}"
        try execute(
            """
            INSERT INTO event(id, aggregate_id, created, type, data)
            VALUES (\(quote(id)), \(quote(session)), \(millis(date)), \(quote(type)), \(quote(data)));
            """
        )
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryReadError.unavailable
        }
    }

    private func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
    }
    private func quoteJSON(_ string: String) -> String {
        String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
    }
    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
}
