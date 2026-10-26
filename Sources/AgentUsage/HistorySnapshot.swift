import Foundation

/// Storage-independent coverage. A readable empty source is a measured zero;
/// missing, unsupported and failed reads cannot establish one.
struct HistoryCoverage: Equatable, Sendable {
    enum State: Sendable { case ready, partial, missing, unavailable, unsupported }
    let state: State
    let hasReadings: Bool
    let issues: Set<HistoryIssue>

    /// Only usable measurements and confirmed absence can replace an accepted contribution.
    var replacesReadings: Bool {
        switch state {
        case .ready, .missing: true
        case .partial: hasReadings
        case .unavailable, .unsupported: false
        }
    }

    static func combined(_ sources: [Self]) -> Self {
        let hasReadings = sources.contains { $0.hasReadings }
        let states = Set(sources.map(\.state))
        let state: State
        if states.isSubset(of: [.ready, .missing]) {
            state = states.contains(.ready) ? .ready : .missing
        } else if hasReadings {
            state = .partial
        } else if states.contains(.unavailable) {
            state = .unavailable
        } else if states.contains(.unsupported) {
            state = .unsupported
        } else {
            state = .partial
        }
        return Self(
            state: state,
            hasReadings: hasReadings,
            issues: sources.reduce(into: []) { $0.formUnion($1.issues) }
        )
    }
}

struct HistorySnapshot: Sendable {
    let summaries: [HistoryPeriod: PeriodSummary]
    let coverage: HistoryCoverage
    let fetchedAt: Date
    /// Pending source reads or continuation batches, not permanent coverage gaps.
    var hasMore = false
    var sources: [HistorySourceSnapshot]

    var visibleSources: [HistorySourceSnapshot] {
        sources.filter { source in
            source.failed
                || (source.coverage.map {
                    $0.state != .missing
                        && ((source.summaries[.month]?.tokens ?? 0) > 0
                            || $0.state != .ready || source.isLoading)
                } ?? false)
        }.sorted { $0.id.name.localizedCaseInsensitiveCompare($1.id.name) == .orderedAscending }
    }
}

extension HistorySourceSnapshot {
    var status: String? {
        let message: String
        if failed {
            message =
                coverage?.hasReadings == true
                ? "Couldn't refresh. Showing older readings." : "History could not be read."
        } else if coverage?.state == .unsupported {
            message = "Unsupported history format."
        } else if coverage?.state == .unavailable {
            message = "History could not be read."
        } else if coverage?.issues.contains(.staleFile) == true {
            message = "Incomplete history. Includes older readings."
        } else {
            return coverage?.warning
        }
        return [message, coverage?.accountingWarning].compactMap { $0 }.joined(separator: " ")
    }
}
