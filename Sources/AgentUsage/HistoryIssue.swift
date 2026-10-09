/// Payload-free coverage gaps. Never retain decoder errors, transcript text, or source paths.
enum HistoryIssue: String, CaseIterable, Sendable {
    case unsupportedVersion, malformedRecord, unsupportedRecord, invalidUsage, incompleteLine
    case scanLimit, toolAggregate, unresolvedFork
    case unreadableFile, changingFile, staleFile, conflictingOperation, oversizedRecord
}
