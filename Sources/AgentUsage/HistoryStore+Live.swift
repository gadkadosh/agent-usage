import Foundation

extension HistoryStore {
    /// Production discovery. Keep each adapter and its index alive across batches and refreshes.
    static func live() -> HistoryStore {
        live(adapters: [
            PiHistorySource(root: PiHistorySource.defaultRoot()),
            CodexHistorySource(home: CodexHistorySource.defaultHome()),
        ])
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
