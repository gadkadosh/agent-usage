import Foundation

/// Source status is separate from token totals: an unreadable source is not zero usage.
struct HistoryCoverage: Equatable, Sendable {
    enum State: Sendable { case ready, partial, missing, unavailable, unsupported }
    let state: State
    let filesRead: Int
    let issues: Set<HistoryIssue>
    /// Readable session files excluded by age, without validating their contents.
    var filesSkipped = 0

    var hasReadings: Bool { filesRead > 0 || filesSkipped > 0 }
}

struct HistorySnapshot: Sendable {
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage
    let fetchedAt: Date
    /// Files deferred by this batch's byte budget, not a permanent coverage gap.
    var hasMoreFiles = false
}
