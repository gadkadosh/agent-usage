import SwiftUI

struct UsagePanel: View {
    let snapshot: UsageSnapshot?
    let error: String?
    let isRefreshing: Bool
    var referenceDate: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    errorCard(error)
                }

                if let snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CHATGPT · ACCOUNT-WIDE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1)

                        limitRow(
                            title: "5-hour window",
                            subtitle: "",
                            color: .orange,
                            window: snapshot.limits.rateLimit.primaryWindow,
                            snapshot: snapshot,
                            now: referenceDate ?? context.date
                        )
                        limitRow(
                            title: "Weekly window",
                            subtitle: "7 days",
                            color: .blue,
                            window: snapshot.limits.rateLimit.secondaryWindow,
                            snapshot: snapshot,
                            now: referenceDate ?? context.date
                        )
                    }
                } else if error == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading allowance…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }

                if snapshot != nil || error != nil {
                    footer
                }
            }
        }
    }

    private func limitRow(
        title: String,
        subtitle: String,
        color: Color,
        window: UsageLimits.Window,
        snapshot: UsageSnapshot,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                if !subtitle.isEmpty {
                    Text("· \(subtitle)")
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
            .accessibilityLabel("\(title) allowance remaining")
            .accessibilityValue("\(window.remaining) remaining")

            Text(snapshot.resetDescription(for: window, at: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                snapshot == nil ? "Allowance unavailable" : "Couldn't refresh allowance",
                systemImage: "exclamationmark.triangle"
            )
            .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
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

    private var footer: some View {
        HStack(spacing: 6) {
            if let snapshot {
                Text(
                    "\(error == nil ? "Updated" : "Last updated"): \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
                )
            } else {
                Text("Not updated yet")
            }

            ProgressView()
                .controlSize(.mini)
                .opacity(isRefreshing ? 1 : 0)
                .accessibilityLabel("Refreshing usage")
                .accessibilityHidden(!isRefreshing)
                .allowsHitTesting(false)

            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
