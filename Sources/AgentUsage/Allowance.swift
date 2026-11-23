import Foundation

/// A subscription whose account-wide allowance the dashboard can show.
enum AllowanceProvider: String, CaseIterable, Sendable {
    case chatGPT
    case claude

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        }
    }
}

/// Fetches one provider's allowance; each provider fails independently.
/// `fetch` must finish within a bounded time, such as a request timeout: a refresh waits for
/// every provider, so one that never returns would stall refreshes for all of them.
struct AllowanceSource: Sendable {
    let provider: AllowanceProvider
    /// Returns nil when the provider has no login, so the dashboard hides it instead of erroring.
    let fetch: @Sendable () async throws -> Allowance?
}

/// Provider-neutral allowance reading, independent of any endpoint's response format.
struct Allowance: Equatable, Sendable {
    let windows: [AllowanceWindow]

    var summary: String {
        windows.map { "\($0.label): \($0.remaining)" }.joined(separator: "  ")
    }

    var lowestRemainingFraction: Double {
        windows.map(\.remainingFraction).min() ?? 1
    }
}

struct AllowanceWindow: Equatable, Sendable {
    /// Short menu-bar label, such as "5h".
    let label: String
    let title: String
    let subtitle: String
    let usedPercent: Double
    let resetsAt: Date

    var remainingFraction: Double {
        min(1, max(0, (100 - usedPercent) / 100))
    }

    var meterOpacity: Double { 0.65 + 0.35 * remainingFraction }

    var remaining: String {
        String(format: "%g", remainingFraction * 100) + "%"
    }

    func resetDescription(at now: Date) -> String {
        let seconds = max(0, resetsAt.timeIntervalSince(now))
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
