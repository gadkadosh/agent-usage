import Foundation

/// An in-memory, per-file index. All IO/parsing/aggregation runs on this actor, not the UI actor.
actor PiHistorySource {
    struct Limits: Sendable {
        var visitedEntries = 20_000
        var fileBytes = 128 * 1_024 * 1_024
        var refreshBytes = 256 * 1_024 * 1_024
        var lineBytes = 8 * 1_024 * 1_024
        var operations = 250_000
    }

    private let root: URL
    private let limits: Limits
    private var cache: [URL: IndexedFile] = [:]
    private var cacheStart: Date?
    private(set) var filesParsed = 0

    init(root: URL, limits: Limits = Limits()) {
        self.root = root.resolvingSymlinksInPath()
        self.limits = limits
    }

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

    func refresh(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws
        -> HistorySnapshot
    {
        try Task.checkCancellation()
        let manager = FileManager.default
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, manager.isReadableFile(atPath: root.path) else {
                throw HistoryReadError.unavailable
            }
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            cache = [:]
            return snapshot(
                [], filesRead: 0, issues: [], state: .missing, now: now, calendar: calendar)
        } catch {
            throw HistoryReadError.unavailable
        }
        var scanFailed = false
        guard
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    scanFailed = true
                    return true
                }
            )
        else { throw HistoryReadError.unavailable }

        var issues: Set<HistoryIssue> = []
        var indexed: [URL: IndexedFile] = [:]
        var observations: [UsageObservation] = []
        var filesRead = 0
        var visited = 0
        var remainingBytes = limits.refreshBytes
        let since = HistoryPeriod.month.start(at: now, calendar: calendar)
        // A clock/timezone change can move the range backwards; cached files may then lack records.
        let previousCache = (cacheStart.map { since >= $0 } ?? true) ? cache : [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= limits.visitedEntries else {
                issues.insert(.scanLimit)
                break
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
            } catch {
                issues.insert(.unreadableFile)
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                issues.insert(.unsupportedRecord)
                continue
            }
            if values.isDirectory == true {
                // Default pi storage: root / encoded-cwd / session.jsonl. Custom roots may be flat.
                if enumerator.level >= 2 {
                    enumerator.skipDescendants()
                    issues.insert(.scanLimit)
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard url.pathExtension == "jsonl" else {
                issues.insert(.unsupportedRecord)
                continue
            }
            let file: IndexedFile
            do {
                guard manager.isReadableFile(atPath: url.path) else {
                    throw HistoryReadError.unavailable
                }
                let before = try signature(url)
                if let cached = previousCache[url], cached.signature == before {
                    file = cached
                    indexed[url] = cached
                } else {
                    let remaining = max(0, limits.operations - observations.count)
                    let parsed = try read(
                        url, since: since, maxOperations: remaining, remainingBytes: &remainingBytes
                    )
                    filesParsed += 1
                    let after = try signature(url)
                    file = IndexedFile(
                        signature: before, observations: parsed.observations, issues: parsed.issues,
                        supported: parsed.isSupported
                    )
                    if before != after {
                        issues.insert(.changingFile)
                        // Don't cache an inconsistent read; retry even if the next size/mtime match.
                    } else if !file.issues.contains(.scanLimit) {
                        indexed[url] = file
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.insert(error is FileLimitError ? .scanLimit : .unreadableFile)
                if let previous = previousCache[url] {
                    file = previous
                    indexed[url] = previous
                    issues.insert(.staleFile)
                } else {
                    continue
                }
            }
            if file.supported { filesRead += 1 }
            issues.formUnion(file.issues)
            let recent = file.observations.filter { $0.timestamp >= since }
            let remaining = max(0, limits.operations - observations.count)
            observations.append(contentsOf: recent.prefix(remaining))
            if recent.count > remaining {
                issues.insert(.scanLimit)
                // Retry the truncated file on the next scan rather than caching an incomplete index.
                indexed.removeValue(forKey: url)
            } else if let entry = indexed[url] {
                indexed[url] = IndexedFile(
                    signature: entry.signature, observations: recent, issues: entry.issues,
                    supported: entry.supported
                )
            }
        }
        if scanFailed {
            if filesRead == 0 { throw HistoryReadError.unavailable }
            issues.insert(.unreadableFile)
        }
        // Deleted files disappear from the index; retain only the last 30 calendar days in memory.
        cache = indexed
        cacheStart = since
        var canonical: [String: UsageObservation] = [:]
        var conflicting: Set<String> = []
        for observation in observations {
            try Task.checkCancellation()
            if let prior = canonical[observation.operationID], prior != observation {
                conflicting.insert(observation.operationID)
                issues.insert(.conflictingOperation)
            } else {
                canonical[observation.operationID] = observation
            }
        }
        for id in conflicting { canonical.removeValue(forKey: id) }
        let state: HistoryCoverage.State
        if filesRead > 0 {
            state = issues.isEmpty ? .ready : .partial
        } else if issues.contains(.unsupportedVersion) {
            state = .unsupported
        } else {
            state = issues.isEmpty ? .missing : .unavailable
        }
        return snapshot(
            Array(canonical.values), filesRead: filesRead, issues: issues, state: state, now: now,
            calendar: calendar)
    }

    private func snapshot(
        _ observations: [UsageObservation], filesRead: Int, issues: Set<HistoryIssue>,
        state: HistoryCoverage.State, now: Date, calendar: Calendar
    ) -> HistorySnapshot {
        HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            observations, period: $0, now: now, calendar: calendar)
                    )
                }),
            coverage: HistoryCoverage(state: state, filesRead: filesRead, issues: issues),
            fetchedAt: now
        )
    }

    private func signature(_ url: URL) throws -> FileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date,
            let created = attributes[.creationDate] as? Date,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw HistoryReadError.unavailable }
        return FileSignature(
            size: size.int64Value, modified: modified, created: created, inode: inode.uint64Value)
    }

    private func read(_ url: URL, since: Date, maxOperations: Int, remainingBytes: inout Int) throws
        -> PiHistoryParser
    {
        guard try signature(url).size <= min(limits.fileBytes, remainingBytes) else {
            throw FileLimitError()
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var parser = PiHistoryParser(since: since, maxOperations: maxOperations)
        var line = Data()
        var bytesRead = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytesRead += chunk.count
            remainingBytes -= chunk.count
            guard bytesRead <= limits.fileBytes, remainingBytes >= 0 else { throw FileLimitError() }
            let pieces = chunk.split(separator: 10, omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                guard line.count + piece.count <= limits.lineBytes else { throw FileLimitError() }
                line.append(contentsOf: piece)
                if index < pieces.count - 1 {
                    parser.consume(line)
                    line.removeAll(keepingCapacity: true)
                }
            }
        }
        if !line.isEmpty { parser.consume(line, terminated: false) }
        parser.finish()
        return parser
    }

    private struct FileSignature: Equatable {
        let size: Int64
        let modified: Date
        let created: Date
        let inode: UInt64
    }

    private struct IndexedFile {
        let signature: FileSignature
        let observations: [UsageObservation]
        let issues: Set<HistoryIssue>
        let supported: Bool
    }

    private struct FileLimitError: Error {}
}

enum HistoryReadError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Pi history could not be read. Check access to the session directory, then refresh."
    }
}
