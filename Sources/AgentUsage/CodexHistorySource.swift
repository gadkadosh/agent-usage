import Foundation

actor CodexHistorySource: HistoryAdapter {
    nonisolated let id = HistoryAgentID.codex
    private let indices: [JSONLHistoryIndex]
    private var accepted: [Int: JSONLHistoryIndex.Result] = [:]

    init(home: URL, limits: JSONLHistoryIndex.Limits = .init()) {
        indices = ["sessions", "archived_sessions"].map {
            JSONLHistoryIndex(
                root: home.appendingPathComponent($0, isDirectory: true),
                limits: limits,
                configuration: .init(
                    makeParser: { _, limit in CodexHistoryParser(maxOperations: limit) },
                    retention: .all
                )
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
        var coverage: [HistoryCoverage] = []
        var more = false
        for (number, index) in indices.enumerated() {
            do {
                let result = try await index.read(request)
                more = more || result.hasMore
                coverage.append(result.coverage)
                issues.formUnion(result.coverage.issues)
                // Each root has its own last usable reading. An unusable result must not
                // erase it just because the other root still makes Codex readable.
                if result.coverage.replacesReadings {
                    accepted[number] = result
                } else if accepted[number]?.coverage.hasReadings == true {
                    issues.insert(.staleFile)
                }
            } catch {
                coverage.append(
                    HistoryCoverage(state: .unavailable, hasReadings: false, issues: [])
                )
                issues.insert(.unreadableFile)
                if accepted[number]?.coverage.hasReadings == true { issues.insert(.staleFile) }
            }
        }
        let results = accepted.values
        issues.formUnion(results.flatMap { $0.coverage.issues })
        let observations = canonicalHistoryObservations(
            results.flatMap(\.candidates),
            format: .codex,
            issues: &issues
        ).filter { $0.timestamp >= request.since }
        let readable = results.contains { $0.coverage.hasReadings }
        let state: HistoryCoverage.State =
            readable
            ? (issues.isEmpty ? .ready : .partial)
            : HistoryCoverage.combined(coverage).state
        return HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(state: state, hasReadings: readable, issues: issues),
            fetchedAt: results.filter { $0.coverage.hasReadings }.map(\.fetchedAt).min()
                ?? request.now,
            hasMore: more
        )
    }
}
