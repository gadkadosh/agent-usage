import CryptoKit
import Foundation

/// Read-only rollout adapter. Contract verified against OpenAI Codex rust-v0.163.0,
/// commit 8308618 (protocol, rollout recorder, session accounting, history wire format).
/// Decode only allowlisted accounting metadata, never transcript or credential fields.
struct CodexHistoryParser: HistoryLineParser {
    private(set) var observations: [UsageObservation] = []
    private(set) var issues: Set<HistoryIssue> = []
    private(set) var isSupported = false
    private let maxOperations: Int
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let iso = ISO8601DateFormatter()
    private var sessionID: String?
    private var turnID: String?
    private var isFork = false
    private var inherited = false
    private var previous: Tokens?
    private var counterSegment = 0
    private var pendingDurableTurn: String?
    private var seenResponses: Set<String> = []
    private var sawHeader = false

    // Keep older accounting metadata: only the source can resolve copies across roots
    // before applying the retention window. A copied envelope may have a newer timestamp.
    init(maxOperations: Int = 250_000) {
        self.maxOperations = maxOperations
    }

    mutating func consume(_ data: Data, terminated: Bool = true) {
        if data.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { return }
        let entry: Entry
        do { entry = try decoder.decode(Entry.self, from: data) } catch {
            issues.insert(terminated ? .malformedRecord : .incompleteLine)
            return
        }
        if !sawHeader {
            sawHeader = true
            guard entry.type == "session_meta", let id = entry.payload?.id, validID(id) else {
                issues.insert(.unsupportedVersion)
                return
            }
            sessionID = id
            isFork = entry.payload?.forkedFromId != nil
            inherited = isFork
            isSupported = true
            return
        }
        guard isSupported, let payload = entry.payload else { return }
        switch entry.type {
        case "session_meta":
            // The recorder writes the child's own header first, followed by copied ancestor
            // headers/history. thread_settings_applied terminates that inherited prefix.
            inherited = payload.id != sessionID
            turnID = nil
        case "turn_context":
            if let id = payload.turnId, validID(id) { turnID = id }
        case "token_usage_record":
            guard let turn = payload.turnId, validID(turn) else {
                issues.insert(.invalidUsage)
                return
            }
            // A durable record names the actual spending thread; inherited records belong
            // to that thread's canonical file, not to this fork/subagent.
            guard payload.threadId == sessionID else { return }
            guard let response = payload.responseId, validID(response),
                let usage = payload.usage, let total = usage.total,
                let timestamp = date(entry.timestamp)
            else {
                issues.insert(.invalidUsage)
                return
            }
            guard observations.count < maxOperations else {
                issues.insert(.scanLimit)
                return
            }
            // A zero-usage response has no positive counter advance to suppress.
            if seenResponses.insert(response).inserted, total > 0 { pendingDurableTurn = turn }
            observations.append(
                observation(
                    total: total,
                    timestamp: timestamp,
                    identity: "response|\(sessionID ?? "")|\(response)"
                )
            )
        case "event_msg":
            switch payload.type {
            case "thread_settings_applied":
                let wasInherited = inherited
                if let owner = payload.threadId {
                    inherited = owner != sessionID
                } else if inherited {
                    issues.insert(.unsupportedRecord)
                }
                // Local settings can follow task_started/turn_context within a live turn.
                // Only discard turn ownership when crossing or reading an inherited prefix.
                if wasInherited || inherited { turnID = nil }
            case "task_started", "turn_started":
                pendingDurableTurn = nil
                turnID = payload.turnId.flatMap { validID($0) ? $0 : nil }
            case "task_complete", "turn_complete", "turn_aborted": turnID = nil
            case "token_count": consumeCounter(payload.info, timestamp: date(entry.timestamp))
            default: break
            }
        case "compacted":
            // Snapshots may contain latest_token_usage_record; those are replay state,
            // not new spending. The cumulative fallback may restart after compaction.
            break
        // Known conversation, review and replay metadata is not additional spending.
        case "response_item", "world_state", "retained_context", "security_risk_score",
            "inter_agent_communication", "inter_agent_communication_metadata", "realtime_item":
            break
        default: issues.insert(.unsupportedRecord)
        }
    }

    private mutating func consumeCounter(_ info: Info?, timestamp: Date?) {
        guard let info else { return }  // Rate-limit-only events carry no usage.
        guard let cumulative = info.totalTokenUsage, cumulative.total != nil else {
            // Invalid reports do not establish a reset or erase a validated baseline.
            issues.insert(.invalidUsage)
            return
        }
        let prior = previous
        // A reset can revisit an earlier cumulative position within the same turn.
        // Segment identities use record order, not copy-rewritten envelope timestamps.
        if let prior, cumulative.input < prior.input || cumulative.output < prior.output {
            counterSegment += 1
        }
        previous = cumulative
        guard !inherited else { return }
        guard let turnID else {
            if cumulative != prior, (cumulative.total ?? 0) > 0 {
                issues.insert(.unsupportedRecord)
            }
            return
        }
        guard cumulative != prior else { return }  // Replay/rate-limit update.
        // Codex 0.163 persists the response record before updating/sending token_count
        // (session accounting and compact.rs). Suppress that paired report, while
        // retaining reports for incomplete responses that have no durable record.
        if pendingDurableTurn == turnID {
            pendingDurableTurn = nil
            return
        }
        guard let timestamp else {
            issues.insert(.invalidUsage)
            return
        }
        let total: Int64
        if let prior {
            // SpendingOnly advances cumulative usage without changing last_token_usage.
            // Input/output deltas capture that spending; context estimates affect total_tokens
            // only. Never bill a reset, even when last usage still looks valid.
            guard cumulative.input >= prior.input, cumulative.output >= prior.output else {
                issues.insert(.invalidUsage)
                return
            }
            total = cumulative.input - prior.input + cumulative.output - prior.output
        } else if isFork {
            // A referenced fork can replay parent usage on a rate-limit update.
            // Without copied counters, this establishes a baseline, not new spending.
            if cumulative.input > 0 || cumulative.output > 0 { issues.insert(.unsupportedRecord) }
            return
        } else {
            guard let usage = info.lastTokenUsage, let initialTotal = usage.total else {
                issues.insert(.invalidUsage)
                return
            }
            if cumulative.input != usage.input || cumulative.output != usage.output {
                issues.insert(.unsupportedRecord)
            }
            total = initialTotal
        }
        guard observations.count < maxOperations else {
            issues.insert(.scanLimit)
            return
        }
        let identity =
            "counter|\(sessionID ?? "")|\(turnID)|\(counterSegment)|\(cumulative.input)|\(cumulative.output)|\(cumulative.cachedInputTokens ?? 0)|\(cumulative.cacheWriteInputTokens ?? 0)"
        observations.append(observation(total: total, timestamp: timestamp, identity: identity))
    }

    mutating func finish() {
        if !sawHeader && issues.isEmpty { issues.insert(.incompleteLine) }
    }

    private func observation(total: Int64, timestamp: Date, identity: String)
        -> UsageObservation
    {
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return UsageObservation(
            operationID: key,
            timestamp: timestamp,
            tokens: total
        )
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }

    private struct Entry: Decodable {
        let type: String
        let timestamp: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let turnId: String?
        let threadId: String?
        let responseId: String?
        let forkedFromId: String?
        let info: Info?
        let usage: Tokens?
    }

    private struct Info: Decodable {
        let totalTokenUsage: Tokens?
        let lastTokenUsage: Tokens?
    }

    private struct Tokens: Decodable, Equatable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cachedInputTokens: Int64?
        let cacheWriteInputTokens: Int64?
        let reasoningOutputTokens: Int64?

        var input: Int64 { inputTokens }
        var output: Int64 { outputTokens }
        var total: Int64? {
            guard (0...1_000_000_000_000).contains(input),
                (0...1_000_000_000_000).contains(output),
                cachedInputTokens.map({ (0...input).contains($0) }) ?? true,
                cacheWriteInputTokens.map({ (0...input).contains($0) }) ?? true,
                reasoningOutputTokens.map({ (0...output).contains($0) }) ?? true
            else { return nil }
            // Cached input and reasoning are subsets, not additional activity.
            return input + output
        }
    }
}
