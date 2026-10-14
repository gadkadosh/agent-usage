import Foundation

extension HistoryStore {
    static func live(
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let pi = PiHistorySource(root: PiHistorySource.defaultRoot())
        let opencode = OpenCodeHistorySource(database: OpenCodeHistorySource.defaultDatabase())
        return live(
            sources: [
                HistorySource(agent: .pi, read: { try await pi.read($0) }),
                HistorySource(agent: .opencode, read: { try await opencode.read($0) }),
            ],
            now: now,
            calendar: calendar
        )
    }

    /// Explicit roots keep integration tests isolated from all installed agents.
    static func live(
        root: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let pi = PiHistorySource(root: root)
        return live(
            sources: [HistorySource(agent: .pi, read: { try await pi.read($0) })],
            now: now,
            calendar: calendar
        )
    }

    static func live(
        sources: [HistorySource],
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let coordinator = HistoryCoordinator(sources: sources)
        return HistoryStore(fetch: { await coordinator.refresh(now: now(), calendar: calendar) })
    }
}
