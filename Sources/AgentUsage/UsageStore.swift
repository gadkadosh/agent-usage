import Foundation
import SwiftUI

struct AllowanceState: Identifiable, Equatable {
    let provider: AllowanceProvider
    var snapshot: UsageSnapshot?
    var error: String?

    var id: AllowanceProvider { provider }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var allowances: [AllowanceState]
    @Published private(set) var isRefreshing = false

    /// The menu bar shows whichever provider is closest to its limit.
    var summary: String {
        let readings = allowances.compactMap(\.snapshot?.allowance)
        if let tightest = readings.min(by: {
            $0.lowestRemainingFraction < $1.lowestRemainingFraction
        }) {
            return tightest.summary
        }
        return allowances.contains { $0.error == nil } ? "Agent Usage…" : "Usage unavailable"
    }

    private let sources: [AllowanceSource]
    private let now: () -> Date
    private var started = false

    init(
        sources: [AllowanceSource] = [.chatGPT],
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

        await withTaskGroup(of: (Int, Result<Allowance, any Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await source.fetch()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            // Publish each provider as it arrives, so a slow one doesn't hold back the others.
            for await (index, result) in group {
                switch result {
                case .success(let allowance):
                    allowances[index].snapshot = UsageSnapshot(
                        allowance: allowance,
                        fetchedAt: now()
                    )
                    allowances[index].error = nil
                case .failure(let error):
                    // Keep the last successful reading, clearly marked as stale in the panel.
                    allowances[index].error = error.localizedDescription
                }
            }
        }
    }
}
