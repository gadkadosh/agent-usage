import Foundation

struct UsageObservation: Equatable, Sendable {
    let operationID: String
    let timestamp: Date
    let tokens: Int64
}

enum HistoryPeriod: Int, CaseIterable, Sendable {
    case today = 1
    case week = 7
    case month = 30

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    func start(at now: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: -(rawValue - 1), to: now)!
        return calendar.startOfDay(for: day)
    }
}

struct HistoryBucket: Equatable, Identifiable, Sendable {
    let start: Date
    let end: Date
    var tokens: Int64 = 0
    var id: Date { start }
}

struct PeriodSummary: Equatable, Sendable {
    let tokens: Int64
    let buckets: [HistoryBucket]

    static func aggregate(
        _ observations: [UsageObservation], period: HistoryPeriod, now: Date, calendar: Calendar
    ) -> Self {
        let start = period.start(at: now, calendar: calendar)
        let end = calendar.dateInterval(of: .day, for: now)!.end
        var buckets: [HistoryBucket] = []
        var cursor = start
        while cursor < end {
            let next = min(
                end,
                period == .today
                    ? calendar.date(byAdding: .hour, value: 1, to: cursor)!
                    : calendar.dateInterval(of: .day, for: cursor)!.end)
            buckets.append(HistoryBucket(start: cursor, end: next))
            cursor = next
        }
        var seen: Set<String> = []
        for observation in observations {
            guard observation.timestamp >= start, observation.timestamp <= now,
                observation.tokens >= 0, seen.insert(observation.operationID).inserted
            else { continue }
            // Locate the actual interval, not a rounded local hour. Half-hour DST shifts can
            // produce a shortened final bucket and local hours that don't round to its start.
            var low = 0
            var high = buckets.count
            while low < high {
                let middle = (low + high) / 2
                if buckets[middle].start <= observation.timestamp {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let index = low - 1
            guard index >= 0, observation.timestamp < buckets[index].end else { continue }
            buckets[index].tokens += observation.tokens
        }
        return Self(tokens: buckets.reduce(0) { $0 + $1.tokens }, buckets: buckets)
    }
}

enum HistoryIssue: String, CaseIterable, Sendable {
    case unsupportedVersion, malformedRecord, unsupportedRecord, invalidUsage, incompleteLine
    case unreadableFile, scanLimit, changingFile, toolAggregate, staleFile, conflictingOperation

    var description: String {
        switch self {
        case .unsupportedVersion:
            "Some files use an unsupported session version (only v2/v3 are supported)."
        case .malformedRecord: "Some records could not be read."
        case .unsupportedRecord: "Some usage records use an unsupported format."
        case .invalidUsage:
            "Some records have missing or invalid token counts, timestamps, or operation IDs."
        case .incompleteLine: "An unfinished record was skipped; it will be retried on refresh."
        case .unreadableFile: "Some history files could not be opened."
        case .scanLimit: "A safety limit was reached; some history was excluded."
        case .changingFile: "A file changed during reading; a consistent reading will be retried."
        case .toolAggregate:
            "Tool-reported usage is included, but may overlap separately saved child sessions."
        case .staleFile: "Last readable data is retained for a file that could not be refreshed."
        case .conflictingOperation: "Conflicting copies of an operation were excluded."
        }
    }
}

struct HistoryCoverage: Equatable, Sendable {
    enum State: Sendable { case ready, partial, missing, unavailable, unsupported }
    let state: State
    let filesRead: Int
    let issues: Set<HistoryIssue>

    var hasReadings: Bool { filesRead > 0 }
}

struct HistorySnapshot: Sendable {
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage
    let fetchedAt: Date
}
