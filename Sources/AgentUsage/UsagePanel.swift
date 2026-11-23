import SwiftUI

struct UsagePanel: View {
    let state: AllowanceState
    let isRefreshing: Bool
    var referenceDate: Date? = nil

    private var snapshot: UsageSnapshot? { state.snapshot }
    private var error: String? { state.error }
    private static let meterColors: [Color] = [.orange, .blue, .purple, .teal]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    errorCard(error)
                }

                if let snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(state.provider.title.uppercased()) · ACCOUNT-WIDE")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1)
                            Spacer(minLength: 8)
                            refreshStatus
                        }

                        let windows = snapshot.allowance.windows
                        ForEach(windows.indices, id: \.self) { index in
                            limitRow(
                                window: windows[index],
                                color: Self.meterColors[index % Self.meterColors.count],
                                now: referenceDate ?? context.date
                            )
                        }
                    }
                } else if error == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(state.provider.title) allowance…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }

                if snapshot == nil && error != nil {
                    refreshStatus
                }
            }
        }
    }

    private func limitRow(window: AllowanceWindow, color: Color, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).fontWeight(.medium)
                if !window.subtitle.isEmpty {
                    Text("· \(window.subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(window.remaining) remaining")
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color.opacity(window.meterOpacity))
                        .frame(width: geometry.size.width * window.remainingFraction)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.title) allowance remaining")
            .accessibilityValue("\(window.remaining) remaining")

            Text(window.resetDescription(at: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                snapshot == nil
                    ? "\(state.provider.title) allowance unavailable"
                    : "Couldn't refresh \(state.provider.title) allowance",
                systemImage: "exclamationmark.triangle"
            )
            .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
            if let retryAt = state.rateLimitedUntil {
                Text("Next check at \(retryAt, format: .dateTime.hour().minute()).")
                    .font(.caption)
            }
            if snapshot != nil {
                Text("Showing the last successful reading. Usage may have changed.")
                    .font(.caption)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var refreshStatus: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .opacity(isRefreshing ? 1 : 0)
                .accessibilityLabel("Refreshing usage")
                .accessibilityHidden(!isRefreshing)
                .allowsHitTesting(false)

            if let snapshot {
                UpdatedTimestamp(
                    date: snapshot.fetchedAt,
                    isStale: error != nil,
                    referenceDate: referenceDate
                )
            } else {
                Text("Not updated yet")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
