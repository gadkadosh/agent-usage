import Darwin
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
    // A narrow injected IO boundary for deterministic concurrent-write/cancellation tests.
    private let didReadFile: @Sendable () throws -> Void
    private var cache: [URL: IndexedFile] = [:]
    private var cacheStart: Date?
    private(set) var filesParsed = 0

    init(
        root: URL,
        limits: Limits = Limits(),
        didReadFile: @escaping @Sendable () throws -> Void = {}
    ) {
        self.root = root.resolvingSymlinksInPath()
        self.limits = limits
        self.didReadFile = didReadFile
    }

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
                [],
                filesRead: 0,
                issues: [],
                state: .missing,
                now: now,
                calendar: calendar
            )
        } catch {
            throw HistoryReadError.unavailable
        }
        // Anchor file opens to the selected root. Never follow descendant directory/file links,
        // including links swapped in after enumeration. The explicitly selected root may be a link.
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw HistoryReadError.unavailable }
        defer { close(rootDescriptor) }
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
        var hasMoreFiles = false
        var madeProgress = false
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
            guard values.isRegularFile == true else {
                issues.insert(.unsupportedRecord)
                continue
            }
            // Lease sidecars are metadata, not session histories.
            if url.lastPathComponent.hasSuffix(".jsonl.lease") { continue }
            guard url.pathExtension == "jsonl" else {
                issues.insert(.unsupportedRecord)
                continue
            }
            // Use enumeration depth rather than stripping an absolute prefix: Foundation may
            // spell the same macOS temporary root as /var/... or /private/var/....
            let relative =
                enumerator.level == 1
                ? [url.lastPathComponent]
                : [url.deletingLastPathComponent().lastPathComponent, url.lastPathComponent]
            let file: IndexedFile
            do {
                guard manager.isReadableFile(atPath: url.path) else {
                    throw HistoryReadError.unavailable
                }
                let handle = try openFile(relative, rootDescriptor: rootDescriptor)
                defer { try? handle.close() }
                let before = try signature(handle)
                if let cached = previousCache[url], cached.signature == before {
                    file = cached
                    indexed[url] = cached
                } else {
                    let remaining = max(0, limits.operations - observations.count)
                    let parsed = try read(
                        handle,
                        size: before.size,
                        since: since,
                        maxOperations: remaining,
                        remainingBytes: &remainingBytes
                    )
                    filesParsed += 1
                    try didReadFile()
                    try Task.checkCancellation()
                    let current = try openFile(relative, rootDescriptor: rootDescriptor)
                    defer { try? current.close() }
                    guard before == (try signature(handle)),
                        before == (try signature(current))
                    else { throw ChangingFileError() }
                    file = IndexedFile(
                        signature: before,
                        observations: parsed.observations,
                        issues: parsed.issues,
                        supported: parsed.isSupported
                    )
                    if !file.issues.contains(.scanLimit) {
                        indexed[url] = file
                        madeProgress = true
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if error is BatchLimitError {
                    hasMoreFiles = true
                } else if error is ChangingFileError {
                    issues.insert(.changingFile)
                } else {
                    issues.insert(error is FileLimitError ? .scanLimit : .unreadableFile)
                }
                if let previous = previousCache[url] {
                    file = previous
                    indexed[url] = previous
                    if !(error is BatchLimitError) { issues.insert(.staleFile) }
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
                    signature: entry.signature,
                    observations: recent,
                    issues: entry.issues,
                    supported: entry.supported
                )
            }
        }
        // An inaccessible subtree is unknown, not deleted. Reject the refresh before replacing
        // the index, so cached files we could not enumerate remain available for the next attempt.
        if scanFailed { throw HistoryReadError.unavailable }
        if hasMoreFiles && observations.count >= limits.operations {
            issues.insert(.scanLimit)
            hasMoreFiles = false
        }
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
        var result = snapshot(
            Array(canonical.values),
            filesRead: filesRead,
            issues: issues,
            state: state,
            now: now,
            calendar: calendar
        )
        // Continue byte-budget deferrals only while the index advances. Failed reads and
        // permanent safety limits must not cause an endless background retry loop.
        result.hasMoreFiles = hasMoreFiles && madeProgress
        try Task.checkCancellation()
        // Commit only a completed refresh. Deleted files disappear; retain 30 calendar days.
        cache = indexed
        cacheStart = since
        return result
    }

    private func snapshot(
        _ observations: [UsageObservation],
        filesRead: Int,
        issues: Set<HistoryIssue>,
        state: HistoryCoverage.State,
        now: Date,
        calendar: Calendar
    ) -> HistorySnapshot {
        HistorySnapshot(
            summaries: Dictionary(
                uniqueKeysWithValues: HistoryPeriod.allCases.map {
                    (
                        $0,
                        PeriodSummary.aggregate(
                            observations,
                            period: $0,
                            now: now,
                            calendar: calendar
                        )
                    )
                }
            ),
            coverage: HistoryCoverage(state: state, filesRead: filesRead, issues: issues),
            fetchedAt: now
        )
    }

    private func openFile(_ relative: [String], rootDescriptor: Int32) throws -> FileHandle {
        guard (1...2).contains(relative.count),
            relative.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw HistoryReadError.unavailable }
        var directory = rootDescriptor
        if relative.count == 2 {
            directory = openat(
                rootDescriptor,
                String(relative[0]),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directory >= 0 else { throw HistoryReadError.unavailable }
        }
        defer { if directory != rootDescriptor { close(directory) } }
        // NONBLOCK also avoids hanging if a regular file is replaced with a FIFO.
        let descriptor = openat(
            directory,
            String(relative.last!),
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw HistoryReadError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            _ = try signature(handle)
            return handle
        } catch {
            try? handle.close()
            throw HistoryReadError.unavailable
        }
    }

    private func signature(_ handle: FileHandle) throws -> FileSignature {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw HistoryReadError.unavailable
        }
        return FileSignature(
            size: info.st_size,
            device: info.st_dev,
            inode: info.st_ino,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec,
            changedNanos: info.st_ctimespec.tv_nsec
        )
    }

    private func read(
        _ handle: FileHandle,
        size: Int64,
        since: Date,
        maxOperations: Int,
        remainingBytes: inout Int
    ) throws -> (observations: [UsageObservation], issues: Set<HistoryIssue>, isSupported: Bool) {
        guard size <= min(limits.fileBytes, limits.refreshBytes) else { throw FileLimitError() }
        guard size <= remainingBytes else { throw BatchLimitError() }
        var parser = PiHistoryParser(since: since, maxOperations: maxOperations)
        var line = Data()
        var bytesRead = 0
        var skippingLine = false
        var oversizedRecord = false
        // Foundation may autorelease read buffers. Drain each read's temporary objects rather
        // than accumulating the archive until the actor's surrounding pool eventually drains.
        // The returned Data stays owned by this iteration, including any slices of the chunk.
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 64 * 1_024) }),
            !chunk.isEmpty
        {
            try Task.checkCancellation()
            bytesRead += chunk.count
            remainingBytes -= chunk.count
            guard bytesRead <= limits.fileBytes, remainingBytes >= 0 else { throw FileLimitError() }
            let pieces = chunk.split(separator: 10, omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                if !skippingLine {
                    if line.count + piece.count > limits.lineBytes {
                        skippingLine = true
                        oversizedRecord = true
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(contentsOf: piece)
                    }
                }
                if index < pieces.count - 1 {
                    if !skippingLine { parser.consume(line) }
                    line.removeAll(keepingCapacity: true)
                    skippingLine = false
                }
            }
        }
        if !line.isEmpty { parser.consume(line, terminated: false) }
        parser.finish()
        // The parser retains only normalized metadata; no record data escapes this function.
        var issues = parser.issues
        if oversizedRecord { issues.insert(.oversizedRecord) }
        return (parser.observations, issues, parser.isSupported)
    }

    private struct FileSignature: Equatable {
        let size: Int64
        let device: Int32
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }

    private struct IndexedFile {
        let signature: FileSignature
        let observations: [UsageObservation]
        let issues: Set<HistoryIssue>
        let supported: Bool
    }

    private struct FileLimitError: Error {}
    private struct BatchLimitError: Error {}
    private struct ChangingFileError: Error {}
}

enum HistoryReadError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Pi history could not be read. Check access to the session directory, then refresh."
    }
}
