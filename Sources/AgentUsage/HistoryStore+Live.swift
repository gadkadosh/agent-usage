import Foundation

extension HistoryStore {
    /// Keep one source actor (and its file index) alive across background batches and refreshes.
    /// Passing a root bypasses default discovery, so integration tests never inspect real histories.
    static func live(
        root: URL? = nil,
        codexHome: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        var adapters: [any HistoryAdapter] = [
            PiHistorySource(root: root ?? PiHistorySource.defaultRoot())
        ]
        // Injecting a Pi root must never discover personal Codex histories in tests/reviews.
        if let home = codexHome ?? (root == nil ? CodexHistorySource.defaultHome() : nil) {
            adapters.append(CodexHistorySource(home: home))
        }
        return live(adapters: adapters, now: now, calendar: calendar)
    }

    /// The same live pipeline with explicitly supplied adapters, without implicit discovery.
    static func live(
        adapters: [any HistoryAdapter],
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let service = HistoryService(adapters: adapters)
        return HistoryStore(fetchUpdates: { update in
            try await service.refresh(now: now(), calendar: calendar, onUpdate: update)
        })
    }
}
