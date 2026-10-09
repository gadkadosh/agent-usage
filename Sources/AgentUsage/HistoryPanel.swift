import Charts
import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var history: HistoryStore
    @State private var hoveredBucketID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PI HISTORY").font(.caption.weight(.semibold)).tracking(1)
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
                    let hoveredBucket = summary.buckets.first { $0.id == hoveredBucketID }
                    HStack {
                        Text("π").font(.title3).accessibilityHidden(true)
                        if let bucket = hoveredBucket {
                            Text(
                                bucket.start.formatted(
                                    date: history.period == .today ? .omitted : .abbreviated,
                                    time: history.period == .today ? .shortened : .omitted
                                )
                            )
                            .fontWeight(.medium)
                        } else {
                            Text("pi").fontWeight(.medium)
                        }
                        Spacer()
                        Text("\((hoveredBucket?.tokens ?? summary.tokens).formatted()) tokens")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                } else if snapshot.hasMoreFiles {
                    Text("Reading pi history…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(snapshot.coverage.emptyDescription)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                historyFooter(snapshot)
            } else if history.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading pi history…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: history.period) { _ in hoveredBucketID = nil }
        .onDisappear { hoveredBucketID = nil }
    }

    @ViewBuilder
    private func historyChart(_ summary: PeriodSummary) -> some View {
        // Aggregated snapshots have buckets, but injected/empty snapshots must also be safe.
        if let first = summary.buckets.first, let last = summary.buckets.last {
            let labels = summary.chartLabelBuckets
            let hoveredBucket = summary.buckets.first { $0.id == hoveredBucketID }
            Chart(summary.buckets) { bucket in
                RectangleMark(
                    xStart: .value("Start", bucket.start),
                    xEnd: .value("End", bucket.barEnd),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Observed tokens", bucket.tokens)
                )
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .opacity(hoveredBucket == nil || bucket.id == hoveredBucketID ? 1 : 0.25)
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
                range: .plotDimension(startPadding: 0, endPadding: 0)
            )
            .chartYScale(domain: 0...max(1, summary.buckets.map(\.tokens).max() ?? 0))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: summary.chartGridlines) { _ in
                    AxisGridLine()
                }
                AxisMarks(values: labels.map(\.barCenter)) { value in
                    if let bucket = labels.first(where: { $0.barCenter == value.as(Date.self) }) {
                        // Edge captions may use the panel margin without hiding or shifting.
                        AxisValueLabel(
                            centered: false,
                            anchor: .top,
                            collisionResolution: .disabled
                        ) {
                            Text(
                                bucket.start,
                                format: history.period == .today
                                    ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
                            )
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let plot = geometry[proxy.plotAreaFrame]
                                guard plot.contains(location),
                                    let date: Date = proxy.value(atX: location.x - plot.minX)
                                else {
                                    hoveredBucketID = nil
                                    return
                                }
                                hoveredBucketID = summary.bucket(at: date)?.id
                            case .ended:
                                hoveredBucketID = nil
                            }
                        }
                }
            }
            .frame(height: 76)
            .onDisappear { hoveredBucketID = nil }
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
                if snapshot.hasMoreFiles && history.isRefreshing {
                    Text("Loading history… Totals are still updating.")
                } else {
                    Text(
                        "\(history.error == nil ? "Updated" : "Last updated"): \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                }
                if history.isRefreshing { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension HistoryBucket {
    var barEnd: Date {
        end.addingTimeInterval(-end.timeIntervalSince(start) * 0.1)
    }

    // Center the caption on the painted rectangle, excluding its trailing gutter.
    var barCenter: Date {
        start.addingTimeInterval(barEnd.timeIntervalSince(start) / 2)
    }
}

extension PeriodSummary {
    // Use the whole interval, including its gutter, so narrow and zero-token bars are readable.
    func bucket(at date: Date) -> HistoryBucket? {
        buckets.first { $0.start <= date && date < $0.end }
    }

    var chartGridlines: [Date] {
        guard let first = buckets.first, let last = buckets.last else { return [] }
        // The fixed 320-point plot has room for individual separators up to seven bars.
        let groups = buckets.count <= 7 ? buckets.count : 3
        let interior = (1..<groups).map { group in
            let index = Int((Double(group) * Double(buckets.count) / Double(groups)).rounded())
            let gapStart = buckets[index - 1].barEnd
            return gapStart.addingTimeInterval(buckets[index].start.timeIntervalSince(gapStart) / 2)
        }
        return [first.start] + interior + [last.end]
    }

    var chartLabelBuckets: [HistoryBucket] {
        let count = min(4, buckets.count)
        guard count > 1 else { return buckets }
        // Include both endpoint bars and distribute the remaining captions between them.
        return (0..<count).map { index in
            let position = Double(index) * Double(buckets.count - 1) / Double(count - 1)
            return buckets[Int(position.rounded())]
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
