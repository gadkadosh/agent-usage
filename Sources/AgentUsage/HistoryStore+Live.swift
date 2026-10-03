import Foundation

extension HistoryStore {
    /// Initial scan, then a minute after each completed scan. See docs/history-scanning.md.
    static let liveRefreshInterval: Duration = .seconds(60)

    /// Keep one source actor (and its file index) alive across initial, polling and manual refreshes.
    /// Passing a root bypasses default discovery, so integration tests never inspect real histories.
    static func live(
        root: URL = PiHistorySource.defaultRoot(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> HistoryStore {
        let source = PiHistorySource(root: root)
        return HistoryStore(fetch: { try await source.refresh(now: now(), calendar: calendar) })
    }
}
