import Foundation

/// Pure line adapter for Claude Code session transcripts, observed in Claude Code 2.1.311–2.1.323.
/// The format is undocumented and adds record types often, so only assistant API responses,
/// the sole carriers of per-response usage, are read; every other record is ignored.
/// One response is written once per content block with identical usage, so `message.id`
/// identifies the operation and the adapter keeps its earliest timestamp. Subagent totals
/// repeated in the parent's tool results are not additional usage. No cost is recorded per
/// response. Never decode transcript fields.
/// Returns candidates: the adapter must deduplicate IDs and exclude conflicting copies.
struct ClaudeCodeHistoryParser: HistoryLineParser {
    private(set) var observations: [UsageObservation] = []
    private(set) var issues: Set<HistoryIssue> = []
    private(set) var isSupported = false
    private let since: Date
    private let maxOperations: Int
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let iso = ISO8601DateFormatter()

    init(since: Date, maxOperations: Int = 250_000) {
        self.since = since
        self.maxOperations = maxOperations
    }

    /// The caller splits on LF and bounds line sizes. A valid final line needs no newline.
    mutating func consume(_ data: Data, terminated: Bool = true) {
        if data.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { return }
        let entry: Entry
        do {
            entry = try decoder.decode(Entry.self, from: data)
        } catch {
            issues.insert(terminated ? .malformedRecord : .incompleteLine)
            return
        }
        isSupported = true
        guard entry.type == "assistant" else { return }
        guard let id = entry.message?.id, !id.isEmpty, id.utf8.count <= 256,
            let tokens = entry.message?.usage?.total,
            let timestamp = parseDate(entry.timestamp)
        else {
            issues.insert(.invalidUsage)
            return
        }
        guard timestamp >= since else { return }
        guard observations.count < maxOperations else {
            issues.insert(.scanLimit)
            return
        }
        observations.append(UsageObservation(operationID: id, timestamp: timestamp, tokens: tokens))
    }

    mutating func finish() {}

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private struct Entry: Decodable {
        let type: String
        let timestamp: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cacheReadInputTokens: Int64?
        let cacheCreationInputTokens: Int64?
        // Cache-creation TTL splits, output details and per-iteration usage are subsets.

        var total: Int64? {
            guard let inputTokens, let outputTokens, let cacheReadInputTokens,
                let cacheCreationInputTokens
            else { return nil }
            let values = [
                inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens,
            ]
            // Defensive per-category bound, not a provider limit; prevents unsafe totals.
            guard values.allSatisfy({ (0...1_000_000_000).contains($0) }) else { return nil }
            return values.reduce(0, +)
        }
    }
}
