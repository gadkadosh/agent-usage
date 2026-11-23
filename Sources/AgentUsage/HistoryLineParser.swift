import Foundation

protocol HistoryLineParser {
    var observations: [UsageObservation] { get }
    var issues: Set<HistoryIssue> { get }
    var isSupported: Bool { get }
    mutating func consume(_ data: Data, terminated: Bool)
    mutating func finish()
}

extension HistoryLineParser {
    mutating func consume(_ data: Data) { consume(data, terminated: true) }
}

func canonicalHistoryObservations(
    _ observations: [UsageObservation],
    issues: inout Set<HistoryIssue>
) -> [UsageObservation] {
    var canonical: [String: UsageObservation] = [:]
    var conflicting: Set<String> = []
    var conflictingCosts: Set<String> = []
    for observation in observations {
        let id = observation.operationID
        guard var prior = canonical[id] else {
            canonical[id] = observation
            continue
        }
        // Cost disagreements invalidate only cost, never otherwise valid token readings.
        guard prior.tokens == observation.tokens else {
            conflicting.insert(id)
            issues.insert(.conflictingOperation)
            continue
        }
        if let old = prior.costUSD, let new = observation.costUSD, old != new {
            conflictingCosts.insert(id)
        }
        prior.costUSD = conflictingCosts.contains(id) ? nil : prior.costUSD ?? observation.costUSD
        // Copies may carry later timestamps: Codex rewrites envelopes when copying a rollout,
        // and Claude Code stamps each content block of one response separately.
        prior.timestamp = min(prior.timestamp, observation.timestamp)
        canonical[id] = prior
    }
    for id in conflicting { canonical.removeValue(forKey: id) }
    return Array(canonical.values)
}
