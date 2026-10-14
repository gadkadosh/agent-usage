import Charts
import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var history: HistoryStore
    // Use the property wrapper, not the macOS 27 macro absent from Command Line Tools.
    private typealias HoverState = SwiftUI.State<Date?>
    @HoverState private var hoveredBucketID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LOCAL HISTORY").font(.caption.weight(.semibold)).tracking(1)
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
                Label("Couldn't refresh local history", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text(error).font(.caption)
                if history.snapshot != nil {
                    Text("Showing the last readable history. Totals may have changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let snapshot = history.snapshot {
                if snapshot.coverage.hasReadings, let summary = history.summary {
                    let hoveredBucket = summary.buckets.first { $0.id == hoveredBucketID }
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            (hoveredBucket?.tokens ?? summary.tokens)
                                .formatted(.number.notation(.compactName))
                        )
                        .font(.system(size: 28, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityLabel(
                            "\(hoveredBucket?.tokens ?? summary.tokens) observed tokens"
                        )
                        Text(
                            hoveredBucket == nil
                                ? "tokens processed"
                                : history.period == .today ? "tokens this hour" : "tokens this day"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                    }
                    historyChart(summary)
                } else if snapshot.hasMoreFiles {
                    Text("Reading local history…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(snapshot.coverage.emptyDescription)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(snapshot.agents) { reading in
                    agentRow(reading)
                }
                historyFooter(snapshot)
            } else if history.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading local history…").font(.caption).foregroundStyle(.secondary)
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
                            .opacity(hoveredBucket == nil ? 1 : 0)
                            .accessibilityHidden(hoveredBucket != nil)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = geometry[proxy.plotAreaFrame]
                    if let bucket = hoveredBucket, let x = proxy.position(forX: bucket.barCenter) {
                        // Keep the axis's existing space and clamp edge labels inside the plot.
                        Text(
                            bucket.start,
                            format: history.period == .today
                                ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in
                            -min(
                                max(x - dimensions.width / 2, 0),
                                max(plot.width - dimensions.width, 0)
                            )
                        }
                        .frame(width: plot.width, height: 18, alignment: .leading)
                        .offset(x: plot.minX, y: plot.maxY)
                        .allowsHitTesting(false)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
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

    private func agentRow(_ reading: AgentHistory) -> some View {
        HStack {
            Text(reading.agent.symbol).font(.title3).accessibilityHidden(true)
            Text(reading.agent.title).fontWeight(.medium)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if reading.coverage.hasReadings, let summary = reading.summaries[history.period] {
                    Text("\(summary.tokens.formatted(.number.notation(.compactName))) tokens")
                        .monospacedDigit()
                        .accessibilityLabel("\(summary.tokens) tokens")
                } else {
                    Text(reading.coverage.sourceStatus).foregroundStyle(.secondary)
                }
                if reading.refreshFailed {
                    Text(
                        reading.coverage.hasReadings
                            ? "Refresh failed · older reading" : "Couldn't refresh"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .help(
                        "Last read: \(reading.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                } else if reading.coverage.state == .partial {
                    Text("Partial history").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
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
        if issues.contains(.unresolvedFork) {
            messages.append("Forked usage may be counted twice.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    var emptyDescription: String {
        switch state {
        case .missing: "No local history found. Missing history isn't zero usage."
        case .unsupported: "Local history was found, but its format isn't supported yet."
        case .unavailable, .partial:
            "Local history was found, but no supported history could be read."
        case .ready: "No recorded usage for this period."
        }
    }

    var sourceStatus: String {
        switch state {
        case .missing: "Not found"
        case .unsupported: "Unsupported format"
        case .unavailable, .partial: "Unavailable"
        case .ready: "No recorded usage"
        }
    }
}
