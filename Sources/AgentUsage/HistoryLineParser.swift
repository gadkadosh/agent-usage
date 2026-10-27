import Foundation

enum HistoryFileFormat: Sendable { case pi, codex }

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
    format: HistoryFileFormat,
    issues: inout Set<HistoryIssue>
) -> [UsageObservation] {
    var canonical: [String: UsageObservation] = [:]
    var conflicting: Set<String> = []
    for observation in observations {
        if let prior = canonical[observation.operationID], prior != observation {
            // Codex rewrites envelope timestamps when copying a rollout. Stable response/turn
            // identities survive the copy. Prefer the original's earliest available timestamp.
            var copy = observation
            copy.timestamp = prior.timestamp
            if format == .codex, copy == prior {
                if observation.timestamp < prior.timestamp {
                    canonical[observation.operationID] = observation
                }
            } else {
                conflicting.insert(observation.operationID)
                issues.insert(.conflictingOperation)
            }
        } else {
            canonical[observation.operationID] = observation
        }
    }
    for id in conflicting { canonical.removeValue(forKey: id) }
    return Array(canonical.values)
}
