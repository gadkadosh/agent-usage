import Foundation

@testable import AgentUsage

// Entirely invented, string-only fixtures based on the official pi v0.99.2 contract.
// No home-directory reads, session files, or SDK calls (loading via pi can migrate files).
enum PiHistoryFixtures {
    static let timestamp = "2026-10-02T10:00:00.000Z"
    static let milliseconds: Int64 = 1_790_935_200_000
    static let since = ISO8601DateFormatter().date(from: "2026-09-03T00:00:00Z")!
    static let tokens =
        #"{"input":100,"output":20,"cacheRead":30,"cacheWrite":40,"reasoning":5,"cacheWrite1h":10,"totalTokens":999,"cost":{"total":123}}"#

    static func header(id: String = "session-a", version: Int = 3, parent: String? = nil) -> String
    {
        let parentField = parent.map { ",\"parentSession\":\"\($0)\"" } ?? ""
        return
            "{\"type\":\"session\",\"version\":\(version),\"id\":\"\(id)\",\"timestamp\":\"\(timestamp)\",\"cwd\":\"/synthetic/workspace\"\(parentField)}"
    }

    static func message(
        id: String = "operation-a", role: String = "assistant", stop: String = "stop",
        usage: String? = tokens, time: Int64 = milliseconds, extra: String = ""
    ) -> String {
        let usageField = usage.map { ",\"usage\":\($0)" } ?? ""
        return
            "{\"type\":\"message\",\"id\":\"\(id)\",\"parentId\":null,\"timestamp\":\"\(timestamp)\",\"message\":{\"role\":\"\(role)\",\"stopReason\":\"\(stop)\",\"timestamp\":\(time)\(usageField)\(extra)}}"
    }

    static func entry(_ type: String, id: String, usage: String? = tokens) -> String {
        let usageField = usage.map { ",\"usage\":\($0)" } ?? ""
        return
            "{\"type\":\"\(type)\",\"id\":\"\(id)\",\"timestamp\":\"\(timestamp)\",\"kind\":\"unknown-operation-kind\"\(usageField)}"
    }

    static func parser(_ lines: [String], maxOperations: Int = 250_000) -> PiHistoryParser {
        var parser = PiHistoryParser(since: since, maxOperations: maxOperations)
        for line in lines { parser.consume(Data(line.utf8)) }
        parser.finish()
        return parser
    }
}
