import Foundation

extension HistoryStore {
    /// Keep both readers alive across background batches and refreshes.
    /// Tests inject both locations (nil disables OpenCode discovery).
    static func live(
        root: URL = PiHistorySource.defaultRoot(),
        openCodeDatabase: URL? = OpenCodeHistorySource.defaultDatabase(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let pi = PiHistorySource(root: root)
        let opencode = OpenCodeHistorySource(database: openCodeDatabase)
        let source = LocalHistorySource(fetchers: [
            .pi: { try await pi.refresh(now: $0, calendar: $1) },
            .opencode: { try await opencode.refresh(now: $0, calendar: $1) },
        ])
        return HistoryStore(fetch: { await source.refresh(now: now(), calendar: calendar) })
    }
}
