import Foundation

@testable import AgentUsage

enum CodexHistoryFixtures {
    static let now = PiHistoryFixtures.now
    static let calendar = PiHistoryFixtures.calendar
    static let time = "2026-10-02T10:00:00.000Z"

    static func line(_ type: String, _ payload: [String: Any], time: String = time) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["type": type, "timestamp": time, "payload": payload],
            options: .sortedKeys
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func header(_ id: String = "thread-a", fork: String? = nil) -> String {
        var fields: [String: Any] = [
            "id": id, "cli_version": "0.163.0", "model_provider": "openai",
        ]
        if let fork { fields["forked_from_id"] = fork }
        return line("session_meta", fields)
    }

    static func start(_ id: String = "turn-a") -> String {
        line("event_msg", ["type": "task_started", "turn_id": id])
    }

    static func settings(_ owner: String) -> String {
        line("event_msg", ["type": "thread_settings_applied", "thread_id": owner])
    }

    static func tokens(_ input: Int, _ output: Int) -> [String: Any] {
        [
            "input_tokens": input, "output_tokens": output, "cached_input_tokens": input / 2,
            "cache_write_input_tokens": 0, "reasoning_output_tokens": output / 2,
            "total_tokens": input + output,
        ]
    }

    static func counter(
        _ input: Int = 100,
        _ output: Int = 20,
        lastInput: Int? = nil,
        lastOutput: Int? = nil
    ) -> String {
        line(
            "event_msg",
            [
                "type": "token_count",
                "info": [
                    "total_token_usage": tokens(input, output),
                    "last_token_usage": tokens(lastInput ?? input, lastOutput ?? output),
                ],
            ]
        )
    }

    static func durable(
        _ response: String = "response-a",
        thread: String = "thread-a",
        turn: String = "turn-a",
        input: Int = 100,
        output: Int = 20
    ) -> String {
        line(
            "token_usage_record",
            [
                "thread_id": thread, "turn_id": turn, "response_id": response,
                "usage": tokens(input, output),
            ]
        )
    }

    static func parse(_ lines: [String], max: Int = 250_000) -> CodexHistoryParser {
        var parser = CodexHistoryParser(since: PiHistoryFixtures.since, maxOperations: max)
        for line in lines { parser.consume(Data(line.utf8)) }
        parser.finish()
        return parser
    }
}
