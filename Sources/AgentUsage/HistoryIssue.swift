/// Payload-free coverage gaps. Never retain decoder errors, transcript text, or source paths.
enum HistoryIssue: String, CaseIterable, Sendable {
    case unsupportedVersion, malformedRecord, unsupportedRecord, invalidUsage, incompleteLine
    case scanLimit, toolAggregate

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
        case .toolAggregate:
            "Tool-reported usage is included, but may overlap separately saved child sessions."
        }
    }
}
