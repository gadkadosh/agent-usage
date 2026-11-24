import Foundation

/// Claude Code discovery uses the shared bounded JSONL index; normalization belongs to the parser.
actor ClaudeCodeHistorySource: HistoryAdapter {
    nonisolated let id = HistoryAgentID.claudeCode
    private let index: JSONLHistoryIndex

    init(root: URL, limits: JSONLHistoryIndex.Limits = .init()) {
        index = JSONLHistoryIndex(
            root: root,
            limits: limits,
            configuration: .init(
                makeParser: { ClaudeCodeHistoryParser(since: $0, maxOperations: $1) },
                retention: .window,
                // Sidecars beside sessions: tool output, memory notes, titles, subagent metadata.
                excludedDirectories: ["tool-results", "memory"],
                ignoredFileSuffixes: [".json"]
            )
        )
    }

    static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let config: URL
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            if override == "~" {
                config = home
            } else if override.hasPrefix("~/") {
                config = home.appendingPathComponent(String(override.dropFirst(2)))
            } else {
                config = URL(fileURLWithPath: override, isDirectory: true)
            }
        } else {
            config = home.appendingPathComponent(".claude", isDirectory: true)
        }
        return config.appendingPathComponent("projects", isDirectory: true)
    }

    func read(_ request: HistoryRequest) async throws -> HistoryAdapterResult {
        try await index.canonicalRead(request)
    }
}
