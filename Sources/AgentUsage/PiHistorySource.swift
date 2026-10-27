import Foundation

/// Pi discovery uses the shared bounded JSONL index; normalization belongs to this adapter.
actor PiHistorySource: HistoryAdapter {
    nonisolated let id = HistoryAgentID.pi
    typealias Limits = JSONLHistoryIndex.Limits
    private let index: JSONLHistoryIndex

    init(
        root: URL,
        limits: Limits = Limits(),
        didReadFile: @escaping @Sendable () throws -> Void = {}
    ) {
        index = JSONLHistoryIndex(
            root: root,
            limits: limits,
            configuration: .init(
                makeParser: { PiHistoryParser(since: $0, maxOperations: $1) },
                retention: .window,
                excludedDirectories: ["subagent-artifacts"],
                ignoredFileSuffixes: [".jsonl.lease"]
            ),
            didReadFile: didReadFile
        )
    }

    var filesParsed: Int { get async { await index.filesParsed } }
    var filesRead: Int { get async { await index.filesRead } }
    var filesSkipped: Int { get async { await index.filesSkipped } }

    // pi v1.0.0 config.ts/main.ts: session-dir env override wins over the agent directory.
    // settings.sessionDir and CLI-only paths are intentionally not read (see coverage limitations).
    static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"], !override.isEmpty {
            if override == "~" { return home }
            if override.hasPrefix("~/") {
                return home.appendingPathComponent(String(override.dropFirst(2)), isDirectory: true)
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return PiCredentialSource.defaultAuthURL(home: home, environment: environment)
            .deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult {
        let result = try await index.read(request)
        var issues = result.coverage.issues
        let observations = canonicalHistoryObservations(
            result.candidates,
            format: .pi,
            issues: &issues
        ).filter { $0.timestamp >= request.since }
        return HistoryAdapterResult(
            observations: observations,
            coverage: HistoryCoverage(
                state: result.coverage.state == .ready && !issues.isEmpty
                    ? .partial : result.coverage.state,
                hasReadings: result.coverage.hasReadings,
                issues: issues
            ),
            fetchedAt: result.fetchedAt,
            hasMore: result.hasMore
        )
    }
}
