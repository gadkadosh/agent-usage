import Foundation
import SQLite3
import XCTest

@testable import AgentUsage

/// Synthetic subset of the v2.0.25 SQLite contract. Never discovers user histories.
struct OpenCodeHistoryFixture: Sendable {
    let root: URL
    var database: URL { root.appendingPathComponent("opencode.db") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try execute(
            """
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, fork_session_id TEXT, fork_boundary TEXT, time_created INTEGER);
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES session_v2(id),
                type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL, data TEXT NOT NULL, UNIQUE(session_id, seq));
            CREATE INDEX session_message_time_created_idx ON session_message(time_created);
            """
        )
        try session("original")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func session(_ id: String, fork: String? = nil) throws {
        try execute(
            "INSERT INTO session_v2 VALUES (\(quote(id)), \(fork.map(quote) ?? "NULL"), NULL, 0)"
        )
    }

    @discardableResult
    func message(
        id: String = "msg_first",
        session: String = "original",
        seq: Int = 1,
        type: String = "assistant",
        at date: Date = PiHistoryFixtures.now,
        data: String? = nil
    ) throws -> String {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1_000)
        let payload = data ?? usage(at: date)
        try execute(
            """
            INSERT OR IGNORE INTO session_message VALUES (
                \(quote(id)), \(quote(session)), \(quote(type)), \(seq), \(milliseconds), \(milliseconds), \(quote(payload)))
            """
        )
        return payload
    }

    func usage(at date: Date = PiHistoryFixtures.now, input: Int = 100) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1_000)
        return """
            {"time":{"created":\(ms),"completed":\(ms + 1000)},
             "tokens":{"input":\(input),"output":20,"reasoning":10,"cache":{"read":30,"write":40}},
             "content":[{"type":"text","text":"Invented transcript: not usage"}],"cost":9876}
            """
    }

    func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw HistoryReadError.unavailable
        }
        return db
    }

    func execute(_ sql: String) throws {
        let db = try open()
        defer { sqlite3_close(db) }
        try Self.execute(sql, on: db)
    }

    static func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail("Synthetic SQLite operation failed")
            throw HistoryReadError.unavailable
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
