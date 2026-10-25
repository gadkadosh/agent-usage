import Foundation

extension HistoryStore {
    /// Keep one source actor (and its file index) alive across background batches and refreshes.
    /// Passing a root bypasses default discovery, so integration tests never inspect real histories.
    static func live(
        root: URL = PiHistorySource.defaultRoot(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        live(adapters: [PiHistorySource(root: root)], now: now, calendar: calendar)
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
