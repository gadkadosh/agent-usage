import CryptoKit
import Foundation

/// Pure line adapter for pi v0.99.2's v2/v3 session JSONL (no IO or SDK loading).
/// Verified tag commit: 005af57d88ee23b33778f343a9595b32e67ff788.
/// Contract: https://github.com/earendil-works/pi/blob/v0.99.2/packages/coding-agent/docs/session-format.md
/// Subsets: https://github.com/earendil-works/pi/blob/v0.99.2/packages/coding-agent/docs/message-types.md
/// Canonical sources: message.usage, usage.usage, compaction.usage, branch_summary.usage.
/// Never decode transcript fields. Tool nestedCalls/details are not additional usage.
/// Returns candidates: the index must deduplicate IDs and exclude conflicting copies.
struct PiHistoryParser {
    private(set) var observations: [UsageObservation] = []
    private(set) var issues: Set<HistoryIssue> = []
    private(set) var isSupported = false
    private var sawHeader = false
    private let since: Date
    private let maxOperations: Int
    private let decoder = JSONDecoder()
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
        if !sawHeader {
            sawHeader = true
            guard entry.type == "session", let version = entry.version, [2, 3].contains(version),
                let id = entry.id, !id.isEmpty
            else {
                issues.insert(.unsupportedVersion)
                return
            }
            isSupported = true
            return
        }
        guard isSupported else { return }

        let usage: Tokens?
        let timestamp: Date?
        let role = entry.message?.role
        switch entry.type {
        case "message":
            guard let message = entry.message else {
                issues.insert(.unsupportedRecord)
                return
            }
            switch message.role {
            case "assistant":
                guard let reason = message.stopReason else {
                    issues.insert(.unsupportedRecord)
                    return
                }
                if reason == "pending" || reason == "deferred" { return }
                guard ["stop", "length", "toolUse", "error", "aborted"].contains(reason) else {
                    issues.insert(.unsupportedRecord)
                    return
                }
                guard message.usage != nil else {
                    issues.insert(.invalidUsage)
                    return
                }
            case "toolResult": break
            default:
                if message.usage != nil { issues.insert(.unsupportedRecord) }
                return
            }
            usage = message.usage
            if let milliseconds = message.timestamp, milliseconds.isFinite, milliseconds >= 0,
                milliseconds < 32_503_680_000_000
            {
                timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            } else {
                timestamp = nil
            }
        case "usage", "compaction", "branch_summary":
            usage = entry.usage
            timestamp = parseDate(entry.timestamp)
            if entry.type == "usage" && usage == nil { issues.insert(.invalidUsage) }
        case "model_change", "thinking_level_change", "context_edit", "custom", "custom_message",
            "label", "session_info":
            if entry.usage != nil { issues.insert(.unsupportedRecord) }
            return
        default:
            issues.insert(.unsupportedRecord)
            return
        }
        guard let usage else { return }
        guard let total = usage.normalizedTotal, let timestamp, let id = entry.id,
            !id.isEmpty, id.utf8.count <= 256
        else {
            issues.insert(.invalidUsage)
            return
        }
        if role == "toolResult" && total > 0 { issues.insert(.toolAggregate) }
        guard timestamp >= since else { return }
        guard observations.count < maxOperations else {
            issues.insert(.scanLimit)
            return
        }
        // Forks/clones preserve id and usage timestamps, but may change parentId and header ID.
        // Include the timestamp and kind to avoid merging unrelated sessions' short random IDs.
        // Hash only allowlisted metadata, never contents or the source path.
        let identity = Identity(id: id, timestamp: timestamp, type: entry.type, role: role)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(identity) else { return }
        let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        observations.append(UsageObservation(operationID: key, timestamp: timestamp, tokens: total))
    }

    mutating func finish() {
        if !sawHeader && issues.isEmpty { issues.insert(.incompleteLine) }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private struct Identity: Encodable {
        let id: String
        let timestamp: Date
        let type: String
        let role: String?
    }

    private struct Entry: Decodable {
        let type: String
        let version: Int?
        let id: String?
        let timestamp: String?
        let message: Message?
        let usage: Tokens?
    }

    private struct Message: Decodable {
        let role: String
        let timestamp: Double?
        let stopReason: String?
        let usage: Tokens?
    }

    private struct Tokens: Decodable {
        let input: Int64?
        let output: Int64?
        let cacheRead: Int64?
        let cacheWrite: Int64?
        // These are subsets, not additional tokens. totalTokens/cost are deliberately ignored.
        let reasoning: Int64?
        let cacheWrite1h: Int64?

        var normalizedTotal: Int64? {
            guard let input, let output, let cacheRead, let cacheWrite else { return nil }
            let values = [input, output, cacheRead, cacheWrite]
            // Defensive per-category bound, not a provider limit; prevents unsafe totals.
            guard values.allSatisfy({ (0...1_000_000_000).contains($0) }),
                reasoning.map({ (0...output).contains($0) }) ?? true,
                cacheWrite1h.map({ (0...cacheWrite).contains($0) }) ?? true
            else { return nil }
            return values.reduce(0, +)
        }
    }
}
