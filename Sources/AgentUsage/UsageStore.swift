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

    /// Providers with a login, or not yet known to be signed out.
    var visibleAllowances: [AllowanceState] { allowances.filter { !$0.isSignedOut } }

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
    private let now: () -> Date
    private var started = false

    init(
        sources: [AllowanceSource] = [.chatGPT, .claude],
        now: @escaping () -> Date = Date.init
    ) {
        self.sources = sources
        self.now = now
        allowances = sources.map { AllowanceState(provider: $0.provider) }
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
            for index in sources.indices {
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
