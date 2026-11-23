import Foundation
import SwiftUI

struct AllowanceState: Identifiable, Equatable {
    let provider: AllowanceProvider
    var snapshot: UsageSnapshot?
    var error: String?
    /// The provider has no login, so the dashboard hides it.
    var isSignedOut = false

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
        if hiddenProviders.isEmpty {
            return
                "No subscription login found. Sign in with Claude Code, or with Codex or pi for ChatGPT, then refresh."
        }
        let hidden = AllowanceProvider.allCases.filter(hiddenProviders.contains).map(\.title)
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
    private let defaults: UserDefaults
    private let now: () -> Date
    private var started = false
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
        if shown { await refresh() }
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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: Reading.self) { group in
            for index in sources.indices where !hiddenProviders.contains(sources[index].provider) {
                let source = sources[index]
                group.addTask {
                    do {
                        return Reading(index: index, allowance: try await source.fetch())
                    } catch {
                        return Reading(index: index, error: error.localizedDescription)
                    }
                }
            }
            // Publish each provider as it arrives, so a slow one doesn't hold back the others.
            for await reading in group {
                let index = reading.index
                if let error = reading.error {
                    // Keep the last successful reading, clearly marked as stale in the panel.
                    allowances[index].error = error
                } else {
                    allowances[index].snapshot = reading.allowance.map {
                        UsageSnapshot(allowance: $0, fetchedAt: now())
                    }
                    allowances[index].error = nil
                }
                allowances[index].isSignedOut = reading.error == nil && reading.allowance == nil
            }
        }
    }
}

/// One provider's refresh outcome. A nil allowance without an error means it has no login.
/// A named type on purpose: Swift 6.4 release builds delivered every `(Int, Result<_, any Error>)`
/// child result with index 0, so one provider's reading overwrote another's.
private struct Reading: Sendable {
    let index: Int
    var allowance: Allowance? = nil
    var error: String? = nil
}
