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
                Text("On this Mac").font(.caption)
            }
            .foregroundStyle(.secondary)

            Picker("History period", selection: $history.period) {
                ForEach(HistoryPeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let error = history.error {
                Label("Couldn't refresh pi history", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text(error).font(.caption)
                if history.snapshot != nil {
                    Text("Showing the last readable history. Totals may have changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let snapshot = history.snapshot {
                if snapshot.coverage.hasReadings, let summary = history.summary {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.tokens.formatted(.number.notation(.compactName)))
                            .font(.system(size: 28, weight: .medium)).monospacedDigit()
                            .accessibilityLabel("\(summary.tokens) observed tokens")
                        Text("tokens processed").font(.caption).foregroundStyle(.secondary)
                    }
                    historyChart(summary)
                    HStack {
                        Text("π").font(.title3).accessibilityHidden(true)
                        Text("pi").fontWeight(.medium)
                        Spacer()
                        Text("\(summary.tokens.formatted()) tokens").monospacedDigit()
                    }
                    .font(.subheadline)
                } else {
                    Text(emptyDescription(snapshot.coverage.state))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                coverageDetails(snapshot)
            } else if history.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading pi history…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func historyChart(_ summary: PeriodSummary) -> some View {
        Chart(summary.buckets) { bucket in
            RectangleMark(
                xStart: .value("Start", bucket.start),
                xEnd: .value(
                    "End",
                    bucket.end.addingTimeInterval(-bucket.end.timeIntervalSince(bucket.start) * 0.1)
                ),
                yStart: .value("Baseline", 0), yEnd: .value("Observed tokens", bucket.tokens)
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
        .chartXScale(domain: summary.buckets.first!.start...summary.buckets.last!.end)
        .chartYScale(domain: 0...max(1, summary.buckets.map(\.tokens).max() ?? 0))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: history.period == .month ? 4 : 5)) {
                AxisGridLine()
                AxisValueLabel(anchor: .topLeading)
            }
        }
        .frame(height: 76)
    }

    private func coverageDetails(_ snapshot: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $history.showsSourceDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        "\(snapshot.coverage.filesRead) supported pi session files read. Observed locally, not account-wide usage or a bill."
                    )
                    ForEach(
                        HistoryIssue.allCases.filter { snapshot.coverage.issues.contains($0) },
                        id: \.self
                    ) { issue in
                        Text(issue.description)
                    }
                    Text(
                        "Default pi storage and environment directory overrides only. Custom settings/CLI locations, ephemeral runs and deleted histories may be missing."
                    )
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
            } label: {
                Text(
                    snapshot.coverage.state == .partial
                        ? "Partial history · details" : "Source details"
                )
                .font(.caption)
            }
            HStack(spacing: 6) {
                Text(
                    "\(history.error == nil ? "History read" : "Last read"): \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
                )
                if history.isRefreshing { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyDescription(_ state: HistoryCoverage.State) -> String {
        switch state {
        case .missing: "No pi history found. Missing history isn't zero usage."
        case .unsupported: "Pi history was found, but its session format isn't supported yet."
        case .unavailable, .partial: "Pi history was found, but no supported files could be read."
        case .ready: "No recorded pi usage for this period."
        }
    }
}
