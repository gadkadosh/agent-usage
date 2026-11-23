import Foundation
import SwiftUI

struct AllowanceState: Identifiable, Equatable {
    let provider: AllowanceProvider
    var snapshot: UsageSnapshot?
    var error: String?
    /// The provider has no login, so the dashboard hides it.
    var isSignedOut = false
    /// Set while the provider's server refuses requests; no request is sent before then.
    var rateLimitedUntil: Date?

    var id: AllowanceProvider { provider }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var allowances: [AllowanceState]
    @Published private(set) var isRefreshing = false
    /// Providers the user turned off; they are neither shown nor fetched.
    @Published private(set) var hiddenProviders: Set<AllowanceProvider>

    /// Shown providers with a login, or not yet known to be signed out.
    var visibleAllowances: [AllowanceState] {
        allowances.filter { !$0.isSignedOut && !hiddenProviders.contains($0.provider) }
    }

    /// Replaces the allowance sections when none is visible.
    var emptyAllowanceMessage: String? {
        guard visibleAllowances.isEmpty else { return nil }
        let hidden = allowances.map(\.provider).filter(hiddenProviders.contains).map(\.title)
        if hidden.isEmpty {
            return
                "No subscription login found. Sign in with Claude Code, or with Codex or pi for ChatGPT, then refresh."
        }
        return "Hidden from the options menu: \(hidden.joined(separator: ", "))."
    }

    /// The menu bar shows whichever provider is closest to its limit.
    var summary: String {
        let visible = visibleAllowances
        if let tightest = visible.compactMap(\.snapshot?.allowance).min(by: {
            $0.lowestRemainingFraction < $1.lowestRemainingFraction
        }) {
            return tightest.summary
        }
        if visible.isEmpty { return "Agent Usage" }
        return visible.contains { $0.error == nil } ? "Agent Usage…" : "Usage unavailable"
    }

    private let sources: [AllowanceSource]
    private var schedules: [FetchSchedule]
    private let defaults: UserDefaults
    private let now: () -> Date
    private var started = false
    private var refreshAgain = false
    private static let hiddenProvidersKey = "hiddenAllowanceProviders"

    init(
        sources: [AllowanceSource] = [.chatGPT, .claude],
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.sources = sources
        self.defaults = defaults
        self.now = now
        allowances = sources.map { AllowanceState(provider: $0.provider) }
        schedules = sources.map { FetchSchedule(interval: $0.provider.refreshInterval) }
        hiddenProviders = Set(
            (defaults.stringArray(forKey: Self.hiddenProvidersKey) ?? [])
                .compactMap(AllowanceProvider.init(rawValue:))
        )
    }

    func setShown(_ provider: AllowanceProvider, _ shown: Bool) async {
        guard hiddenProviders.contains(provider) == shown else { return }
        if shown {
            hiddenProviders.remove(provider)
        } else {
            hiddenProviders.insert(provider)
        }
        defaults.set(hiddenProviders.map(\.rawValue).sorted(), forKey: Self.hiddenProvidersKey)
        guard shown else { return }
        // A due provider's last reading is older than its interval, so show it loading instead.
        let start = now()
        for index in allowances.indices
        where allowances[index].provider == provider && schedules[index].isDue(at: start) {
            allowances[index] = AllowanceState(provider: provider)
        }
        await refresh()
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Fetches only the providers whose schedule is due, so Refresh can't exceed their limits.
    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // A request during a pass may need what that pass skipped, such as a provider just shown.
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        let start = now()
        let due = sources.indices.filter {
            !hiddenProviders.contains(sources[$0].provider) && schedules[$0].isDue(at: start)
        }
        await withTaskGroup(of: Reading.self) { group in
            for index in due {
                let source = sources[index]
                group.addTask {
                    do {
                        return Reading(index: index, allowance: try await source.fetch())
                    } catch {
                        return Reading(index: index, error: error)
                    }
                }
            }
            // Publish each provider as it arrives, so a slow one doesn't hold back the others.
            for await reading in group {
                let index = reading.index
                let finishedAt = now()
                allowances[index].rateLimitedUntil = nil
                if case UsageError.rateLimited(let retryAfter)? = reading.error {
                    allowances[index].rateLimitedUntil = schedules[index].rateLimited(
                        at: finishedAt,
                        retryAfter: retryAfter
                    )
                } else if reading.error != nil {
                    schedules[index].failed()
                } else {
                    schedules[index].succeeded(at: finishedAt)
                    allowances[index].snapshot = reading.allowance.map {
                        UsageSnapshot(allowance: $0, fetchedAt: finishedAt)
                    }
                }
                // Keep the last successful reading, clearly marked as stale in the panel.
                allowances[index].error = reading.error?.localizedDescription
                allowances[index].isSignedOut = reading.error == nil && reading.allowance == nil
            }
        }
    }
}

/// When a provider may be asked again.
struct FetchSchedule {
    let interval: TimeInterval
    private var nextFetch: Date?
    private var rateLimits = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func isDue(at now: Date) -> Bool {
        nextFetch.map { now >= $0 } ?? true
    }

    mutating func succeeded(at now: Date) {
        rateLimits = 0
        nextFetch = now.addingTimeInterval(interval)
    }

    /// Retry at the next poll or Refresh, so a fixed login or connection shows up right away.
    mutating func failed() {
        nextFetch = nil
    }

    /// Waits at least as long as the server asks, which may be 0 or missing, and backs off from
    /// 5 to 30 minutes while it keeps refusing, so polling never keeps the limit from clearing.
    mutating func rateLimited(at now: Date, retryAfter: TimeInterval?) -> Date {
        rateLimits += 1
        let backoff = min(30 * 60, 5 * 60 * pow(2, Double(rateLimits - 1)))
        let retryAt = now.addingTimeInterval(max(backoff, retryAfter ?? 0))
        nextFetch = retryAt
        return retryAt
    }
}

/// One provider's refresh outcome. A nil allowance without an error means it has no login.
/// A named type on purpose: Swift 6.4 release builds delivered every `(Int, Result<_, any Error>)`
/// child result with index 0, so one provider's reading overwrote another's.
private struct Reading: Sendable {
    let index: Int
    var allowance: Allowance? = nil
    var error: (any Error)? = nil
}
