import Foundation

/// Source status is separate from token totals: an unreadable source is not zero usage.
struct HistoryCoverage: Equatable, Sendable {
    enum State: Sendable { case ready, partial, missing, unavailable, unsupported }
    let state: State
    let filesRead: Int
    let issues: Set<HistoryIssue>

    var hasReadings: Bool { filesRead > 0 }

    /// Scope caveats, even for a successful scan. No settings or parent-session paths are read.
    static let limitations = [
        "Only the selected pi session root is indexed (flat files or one project-directory level).",
        "Hidden files and package directories are not scanned; compressed histories are unsupported.",
        "Custom settings.sessionDir and CLI-only session paths outside this root are not discovered.",
        "Ephemeral sessions and histories on other computers are not available.",
    ]
}

struct HistorySnapshot: Sendable {
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage
    let fetchedAt: Date
}
