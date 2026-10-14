import Foundation

enum HistoryReadError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Local history could not be read. Check access to the history storage, then refresh."
    }
}

/// Identifies a local history producer, not a model provider or allowance account.
enum HistoryAgent: String, CaseIterable, Identifiable, Sendable {
    case pi, opencode
    var id: Self { self }
    var title: String { self == .pi ? "pi" : "OpenCode" }
}

struct HistoryReadContext: Sendable {
    let now: Date
    let calendar: Calendar
    var since: Date { HistoryPeriod.month.start(at: now, calendar: calendar) }
}

/// Storage-specific discovery, consistency, and indexing stay inside each adapter.
struct HistorySource: Sendable {
    let agent: HistoryAgent
    let read: @Sendable (HistoryReadContext) async throws -> HistoryReadings
}

/// Canonical operations within one agent's identity namespace. No payloads or paths.
struct HistoryReadings: Sendable {
    let observations: [UsageObservation]
    let coverage: HistoryCoverage
    var hasMoreFiles = false

    func snapshot(in context: HistoryReadContext) -> HistorySnapshot {
        HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            observations,
                            period: $0,
                            now: context.now,
                            calendar: context.calendar
                        )
                    )
                }
            ),
            coverage: coverage,
            fetchedAt: context.now,
            hasMoreFiles: hasMoreFiles
        )
    }
}

struct AgentHistorySummary: Identifiable, Sendable {
    let agent: HistoryAgent
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage
    let fetchedAt: Date?
    let refreshFailed: Bool
    let isLoading: Bool
    var id: HistoryAgent { agent }
}
