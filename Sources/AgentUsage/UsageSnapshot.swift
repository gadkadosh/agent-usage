import Foundation

struct UsageSnapshot {
    let limits: UsageLimits
    let fetchedAt: Date

    func resetDescription(for window: UsageLimits.Window, at now: Date) -> String {
        let resetAt = fetchedAt.addingTimeInterval(TimeInterval(window.resetAfterSeconds))
        let seconds = max(0, resetAt.timeIntervalSince(now))
        if seconds <= 0 { return "Reset due" }
        if seconds < 60 { return "Resets in <1m" }

        let minutes = Int(ceil(seconds / 60))
        let hours = minutes / 60
        let days = hours / 24
        let duration: String
        if days > 0 {
            duration = "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            duration = "\(hours)h \(minutes % 60)m"
        } else {
            duration = "\(minutes)m"
        }
        return "Resets in \(duration)"
    }
}
