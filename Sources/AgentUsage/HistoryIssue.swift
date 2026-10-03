/// Payload-free coverage gaps. Never retain decoder errors, transcript text, or source paths.
enum HistoryIssue: String, CaseIterable, Sendable {
    case unsupportedVersion, malformedRecord, unsupportedRecord, invalidUsage, incompleteLine
    case scanLimit, toolAggregate
    case unreadableFile, changingFile, staleFile, conflictingOperation, oversizedRecord

    var description: String {
        switch self {
        case .unsupportedVersion:
            "Some files use an unsupported session version (only v2/v3 are supported)."
        case .malformedRecord: "Some records could not be read."
        case .unsupportedRecord: "Some usage records use an unsupported format."
        case .invalidUsage:
            "Some records have missing or invalid token counts, timestamps, or operation IDs."
        case .incompleteLine: "An unfinished record was skipped."
        case .scanLimit: "A safety limit was reached; some history was excluded."
        case .unreadableFile: "Some history files could not be opened."
        case .changingFile: "A file changed during reading; a consistent reading will be retried."
        case .staleFile: "Last readable data is retained for a file that could not be refreshed."
        case .conflictingOperation: "Conflicting copies of an operation were excluded."
        case .oversizedRecord: "Some records exceed the size limit and were skipped."
        case .toolAggregate:
            "Tool-reported usage is included, but may overlap separately saved child sessions."
        }
    }
}
