import SwiftUI

struct UsagePanel: View {
    let snapshot: UsageSnapshot?
    let error: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()

                if let error {
                    errorCard(error)
                }

                if let snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("LIMITS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1)

                        limitRow(
                            title: "Session", subtitle: "5 hours",
                            window: snapshot.limits.rateLimit.primaryWindow,
                            snapshot: snapshot, now: context.date
                        )
                        limitRow(
                            title: "Weekly", subtitle: "7 days",
                            window: snapshot.limits.rateLimit.secondaryWindow,
                            snapshot: snapshot, now: context.date
                        )
                    }

                    Text("\(error == nil ? "Updated" : "Last updated") \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if error == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading usage…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }

                Divider()
                footer
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex")
                    .font(.title2.weight(.semibold))
                Text("ChatGPT subscription")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func limitRow(
        title: String, subtitle: String, window: UsageLimits.Window,
        snapshot: UsageSnapshot, now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Text("· \(subtitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.used) used")
                    .monospacedDigit()
                    .foregroundStyle(window.isNearLimit ? Color.orange : Color.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(window.isNearLimit ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * window.usedFraction)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) allowance used")
            .accessibilityValue(window.used)

            HStack {
                Text("\(window.remaining) remaining")
                Spacer()
                Text(snapshot.resetDescription(for: window, at: now))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(snapshot == nil ? "Usage unavailable" : "Couldn't refresh usage", systemImage: "exclamationmark.triangle")
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
        HStack {
            Button(action: onRefresh) {
                Label(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()
            Button("Quit", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit Agent Usage")
        }
    }
}
