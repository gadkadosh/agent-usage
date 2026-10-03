import Foundation

/// One-shot mutation at the injected read boundary, synchronized across test/source actors.
final class ReadAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?

    func arm(_ action: @escaping @Sendable () throws -> Void) {
        lock.withLock { self.action = action }
    }

    func run() throws {
        let next = lock.withLock {
            let next = action
            action = nil
            return next
        }
        try next?()
    }
}
