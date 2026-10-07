import Foundation

/// Source status is separate from token totals: an unreadable source is not zero usage.
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
