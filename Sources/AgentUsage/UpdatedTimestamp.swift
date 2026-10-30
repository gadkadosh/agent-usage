import SwiftUI

struct UpdatedTimestamp: View {
    let date: Date
    var isStale = false
    var referenceDate: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(
                "\(isStale ? "Last updated" : "Updated") \(Self.timestamp(for: date, relativeTo: referenceDate ?? context.date))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .complete, time: .standard))
            .accessibilityLabel(
                "\(isStale ? "Last updated" : "Updated") \(date.formatted(date: .complete, time: .standard))"
            )
        }
    }

    static func timestamp(
        for date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
