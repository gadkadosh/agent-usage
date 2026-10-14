import CryptoKit
import Foundation

/// OpenCode v2.0.25, commit b44eea9e204024db2b480a136ece29d790d5f593.
/// Contract: packages/{core/src/session/{sql,usage},schema/src/{session-message,token-usage}}.ts
/// v2 output is visible output; reasoning is ADDITIVE. Cache categories exclude ordinary input.
/// Read only canonical session_message rows, never event logs, tool content or session totals.
struct OpenCodeHistoryParser {
    private(set) var observations: [UsageObservation] = []
    private(set) var issues: Set<HistoryIssue> = []
    private let decoder = JSONDecoder()

    /// Metadata is projected by SQL; transcript fields never leave SQLite.
    mutating func consume(id: String, type: String, created: Double, metadata: Data) {
        guard let record = try? decoder.decode(Record.self, from: metadata) else {
            issues.insert(.malformedRecord)
            return
        }
        guard ["assistant", "compaction"].contains(type) else {
            if record.hasTokens
                || ![
                    "agent-switched", "model-switched", "location-switched", "user", "synthetic",
                    "system", "skill", "shell", "idle",
                ].contains(type)
            {
                issues.insert(.unsupportedRecord)
            }
            return
        }
        // Usage is optional on in-flight messages and compactions without a provider response.
        guard record.hasTokens else { return }
        guard !id.isEmpty, id.utf8.count <= 256,
            created.isFinite, (0..<32_503_680_000_000).contains(created),
            record.created == created,
            let tokens = record.tokens.total
        else {
            issues.insert(.invalidUsage)
            return
        }
        let identity = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        observations.append(
            UsageObservation(
                operationID: identity,
                timestamp: Date(timeIntervalSince1970: created / 1_000),
                tokens: tokens
            )
        )
    }

    private struct Record: Decodable {
        let hasTokens: Bool
        let created: Double?
        let tokens: Tokens
    }

    private struct Tokens: Decodable {
        let input: Int64?
        let output: Int64?
        let reasoning: Int64?
        let cacheRead: Int64?
        let cacheWrite: Int64?

        var total: Int64? {
            let values = [input, output, reasoning, cacheRead, cacheWrite]
            guard values.allSatisfy({ $0.map { (0...1_000_000_000).contains($0) } ?? false }) else {
                return nil
            }
            return values.reduce(0) { $0 + $1! }
        }
    }
}
