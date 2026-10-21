import Foundation

/// A normalized operation. Adapters supply stable identities and validated token totals;
/// they must resolve conflicting records before aggregation. No transcripts or credentials.
struct UsageObservation: Equatable, Sendable {
    let operationID: String
    var timestamp: Date
    let tokens: Int64
    var detail: TokenDetail?
    var model: String?
    var provider: String?
}

/// Input includes cached input; output includes reasoning. Unknown detail stays nil.
struct TokenDetail: Equatable, Sendable {
    let input: Int64
    let output: Int64
    let cachedInput: Int64?
    let cacheWriteInput: Int64?
    let reasoningOutput: Int64?
}

func historyMetadata(_ value: String?) -> String? {
    value.flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
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
        _ observations: [UsageObservation],
        period: HistoryPeriod,
        now: Date,
        calendar: Calendar
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
                    : calendar.dateInterval(of: .day, for: cursor)!.end
            )
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
