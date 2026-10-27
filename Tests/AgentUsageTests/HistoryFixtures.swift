import Foundation

@testable import AgentUsage

/// Shared synthetic clock and summaries; no agent format, discovery or credentials.
enum HistoryFixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
}

// Keep source-focused assertions on presentation summaries without aggregation in the adapters.
extension HistoryAdapter {
    func refresh(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) async throws
        -> HistorySnapshot
    {
        let result = try await read(HistoryRequest(now: now, calendar: calendar))
        let summaries = historySummaries(result.observations, now: now, calendar: calendar)
        return HistorySnapshot(
            summaries: summaries,
            coverage: result.coverage,
            fetchedAt: result.fetchedAt,
            hasMore: result.hasMore,
            sources: [
                HistorySourceSnapshot(
                    id: id,
                    summaries: summaries,
                    coverage: result.coverage,
                    fetchedAt: result.fetchedAt,
                    failed: false,
                    isLoading: result.hasMore
                )
            ]
        )
    }
}
