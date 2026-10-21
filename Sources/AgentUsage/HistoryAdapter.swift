import Foundation

enum HistoryReadError: Error, Equatable { case unavailable }

struct HistoryAgentID: Hashable, Sendable {
    let rawValue: String
    static let pi = Self(rawValue: "pi")
    static let codex = Self(rawValue: "codex")

    var name: String { self == .codex ? "Codex" : self == .pi ? "pi" : rawValue }
    var symbol: String { self == .pi ? "π" : "⌘" }
}

struct HistoryRequest: Sendable {
    let now: Date
    let calendar: Calendar
    let since: Date

    init(now: Date, calendar: Calendar) {
        self.now = now
        // Freeze an autoupdating calendar for the entire refresh, including catch-up.
        var fixedCalendar = calendar
        fixedCalendar.timeZone = calendar.timeZone
        self.calendar = fixedCalendar
        since = HistoryPeriod.month.start(at: now, calendar: fixedCalendar)
    }
}

/// A complete replacement of the adapter's accepted observations for the requested window.
/// Continuation batches include earlier accepted records; consumers never append results.
struct HistoryAdapterResult: Sendable {
    let observations: [UsageObservation]
    let coverage: HistoryCoverage
    let fetchedAt: Date
    var hasMore = false
}

/// Implementations own discovery, IO, indexing, normalization and duplicate/conflict resolution.
/// Ready and usable partial results replace all accepted observations, including deletions.
/// Missing clears the contribution. Unsupported/unavailable results (or thrown failures)
/// retain the previous contribution. Only accepted results may request continuation.
/// No transcript content, credentials or raw IO errors cross this boundary.
protocol HistoryAdapter: Sendable {
    var id: HistoryAgentID { get }
    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult
}

struct HistorySourceSnapshot: Sendable {
    let id: HistoryAgentID
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage?
    let fetchedAt: Date?
    let failed: Bool
    var isLoading = false
}

func historySummaries(
    _ observations: [UsageObservation],
    now: Date,
    calendar: Calendar
) -> [HistoryPeriod: PeriodSummary] {
    Dictionary(
        uniqueKeysWithValues: HistoryPeriod.allCases.map {
            ($0, PeriodSummary.aggregate(observations, period: $0, now: now, calendar: calendar))
        }
    )
}
