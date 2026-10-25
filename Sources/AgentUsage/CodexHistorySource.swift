import Foundation

actor CodexHistorySource: HistoryAdapter {
    nonisolated let id = HistoryAgentID.codex
    private let indices: [JSONLHistoryIndex]
    private var accepted: [Int: HistoryAdapterResult] = [:]

    init(home: URL, limits: JSONLHistoryIndex.Limits = .init()) {
        indices = ["sessions", "archived_sessions"].map {
            JSONLHistoryIndex(
                root: home.appendingPathComponent($0, isDirectory: true),
                limits: limits,
                format: .codex
            )
        }
    }

    static func defaultHome(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let override = environment["CODEX_HOME"], !override.isEmpty else {
            return home.appendingPathComponent(".codex", isDirectory: true)
        }
        if override == "~" { return home }
        if override.hasPrefix("~/") {
            return home.appendingPathComponent(String(override.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult {
        var issues: Set<HistoryIssue> = []
        var more = false
        for (number, index) in indices.enumerated() {
            do {
                let result = try await index.read(request)
                accepted[number] = result
                more = more || result.hasMore
            } catch {
                issues.insert(.unreadableFile)
                if accepted[number] != nil { issues.insert(.staleFile) }
            }
        }
        let results = accepted.values
        issues.formUnion(results.flatMap { $0.coverage.issues })
        let observations = canonicalHistoryObservations(
            results.flatMap(\.observations),
            format: .codex,
            issues: &issues
        ).filter { $0.timestamp >= request.since }
        let readable = results.contains { $0.coverage.hasReadings }
        let present = results.contains { $0.coverage.state != .missing }
        let state: HistoryCoverage.State =
            readable
            ? (issues.isEmpty ? .ready : .partial)
            : !issues.isEmpty ? .unavailable : present ? .unsupported : .missing
        return HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(state: state, hasReadings: readable, issues: issues),
            fetchedAt: request.now,
            hasMore: more
        )
    }
}
