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
        var coverage: [HistoryCoverage] = []
        var more = false
        for (number, index) in indices.enumerated() {
            do {
                var result = try await index.read(request)
                // An unusable batch can still defer readable files. Advance it internally
                // until it can publish a usable result or has no further progress to make.
                while !result.coverage.replacesReadings && result.hasMore {
                    result = try await index.read(request)
                }
                coverage.append(result.coverage)
                issues.formUnion(result.coverage.issues)
                // Each root has its own last usable reading. An unusable result must not
                // erase it just because the other root still makes Codex readable.
                if result.coverage.replacesReadings {
                    accepted[number] = result
                    more = more || result.hasMore
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
            results.flatMap(\.observations),
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
