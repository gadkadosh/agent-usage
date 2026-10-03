import Foundation

// Synthetic roots only. Never load agent SDKs or fall through to a real home directory.
struct PiHistoryFixtureRoot {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(
        _ path: String = "--synthetic--/session.jsonl", lines: [String], ending: String = "\n"
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + ending).utf8).write(to: url, options: .atomic)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
