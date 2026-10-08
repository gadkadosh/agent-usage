import Charts
import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PI HISTORY")
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                Spacer()
                Text("On this Mac")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            Picker("History period", selection: $history.period) {
                ForEach(HistoryPeriod.allCases, id: \.self) { period in
                    Text(period.title)
                        .tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let error = history.error {
                Label("Couldn't refresh pi history", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text(error)
                    .font(.caption)
                if history.snapshot != nil {
                    Text("Showing the last readable history. Totals may have changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = history.snapshot {
                if snapshot.coverage.hasReadings, let summary = history.summary {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.tokens.formatted(.number.notation(.compactName)))
                            .font(.system(size: 28, weight: .medium))
                            .monospacedDigit()
                            .accessibilityLabel("\(summary.tokens) observed tokens")
                        Text("tokens processed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    historyChart(summary)
                    HStack {
                        Text("π")
                            .font(.title3)
                            .accessibilityHidden(true)
                        Text("pi")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(summary.tokens.formatted()) tokens")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                } else {
                    Text(snapshot.coverage.emptyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                historyFooter(snapshot)
            } else if history.error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading pi history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func historyChart(_ summary: PeriodSummary) -> some View {
        // Aggregated snapshots have buckets, but injected/empty snapshots must also be safe.
        if let first = summary.buckets.first, let last = summary.buckets.last {
            Chart(summary.buckets) { bucket in
                RectangleMark(
                    xStart: .value("Start", bucket.start),
                    xEnd: .value(
                        "End",
                        bucket.end.addingTimeInterval(
                            -bucket.end.timeIntervalSince(bucket.start) * 0.1
                        )
                    ),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Observed tokens", bucket.tokens)
                )
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .accessibilityLabel(
                    bucket.start.formatted(
                        date: history.period == .today ? .omitted : .abbreviated,
                        time: history.period == .today ? .shortened : .omitted
                    )
                )
                .accessibilityValue("\(bucket.tokens) tokens")
            }
            .chartXScale(
                domain: first.start...last.end,
                range: .plotDimension(startPadding: 0, endPadding: 28)
            )
            .chartYScale(domain: 0...max(1, summary.buckets.map(\.tokens).max() ?? 0))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: history.period == .month ? 3 : 4)) {
                    AxisGridLine()
                    AxisValueLabel(anchor: .topLeading)
                }
            }
            .frame(height: 76)
        }
    }

    private func historyFooter(_ snapshot: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning = snapshot.coverage.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(
                    "\(history.error == nil ? "Updated" : "Last updated"): \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                if history.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension HistoryCoverage {
    /// Show only caveats that affect the displayed totals. Empty states explain themselves.
    var warning: String? {
        guard hasReadings else { return nil }
        var messages: [String] = []
        if state == .partial { messages.append("Partial history. Totals may be incomplete.") }
        if issues.contains(.staleFile) { messages.append("Includes older readings.") }
        if issues.contains(.toolAggregate) { messages.append("Tool usage may be counted twice.") }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    var emptyDescription: String {
        switch state {
        case .missing: "No pi history found. Missing history isn't zero usage."
        case .unsupported: "Pi history was found, but its session format isn't supported yet."
        case .unavailable, .partial: "Pi history was found, but no supported files could be read."
        case .ready: "No recorded pi usage for this period."
        }
    }
}
