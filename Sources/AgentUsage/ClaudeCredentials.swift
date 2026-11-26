import Foundation
import Security
import os

struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date

    /// Reads only the subscription access token and its expiry from Claude Code's Keychain item.
    /// Returns nil when the item holds no Claude subscription login.
    static func parse(_ data: Data) throws -> ClaudeCredentials? {
        let item: Item
        do {
            item = try JSONDecoder().decode(Item.self, from: data)
        } catch {
            // Decoder errors can contain credential values. Never expose them.
            throw ClaudeCredentialError.invalidLogin
        }
        guard let oauth = item.claudeAiOauth else { return nil }
        guard let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty, !token.contains(where: \.isWhitespace),
            let expiresAt = oauth.expiresAt, expiresAt.isFinite
        else { throw ClaudeCredentialError.invalidLogin }
        // Claude Code stores expiry as Unix milliseconds, not seconds.
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: expiresAt / 1_000)
        )
    }

    private struct Item: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
    }
}

/// Reads Claude Code's login without refreshing or modifying it.
/// The token is kept in memory until it expires or is rejected, so the Keychain is read once
/// per token rather than on every refresh.
actor ClaudeLogin {
    static let service = "Claude Code-credentials"

    private let keychain: any KeychainReading
    private let timeout: Duration
    private var cached: ClaudeCredentials?
    /// Shared by overlapping refreshes, so a pending access prompt never stacks another.
    private var read: Task<Data?, any Error>?

    init(keychain: any KeychainReading = SystemKeychain(), timeout: Duration = .seconds(15)) {
        self.keychain = keychain
        self.timeout = timeout
    }

    /// Returns nil when Claude Code has no subscription login.
    func credentials(now: Date) async throws -> ClaudeCredentials? {
        if let cached, cached.expiresAt > now { return cached }
        cached = nil
        guard let data = try await readKeychain(),
            let credentials = try ClaudeCredentials.parse(data)
        else { return nil }
        guard credentials.expiresAt > now else { throw ClaudeCredentialError.expiredLogin }
        cached = credentials
        return credentials
    }

    /// Forget a token the server rejected, so the next refresh rereads the Keychain.
    func discard(_ credentials: ClaudeCredentials) {
        if cached == credentials { cached = nil }
    }

    private func readKeychain() async throws -> Data? {
        let task =
            read
            ?? Task { [keychain] in
                // Keychain reads block while macOS asks to unlock it; keep them off the shared pool.
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(
                            with: Result { try keychain.genericPassword(service: Self.service) }
                        )
                    }
                }
            }
        read = task
        let result = await Self.result(of: task, within: timeout)
        // A timed-out read stays shared until it finishes; a later refresh collects it.
        if result != nil, read == task { read = nil }
        switch result {
        case nil:
            throw ClaudeCredentialError.keychainPending
        case .success(let data):
            return data
        case .failure(KeychainError.denied):
            throw ClaudeCredentialError.keychainDenied
        case .failure:
            throw ClaudeCredentialError.unreadableLogin
        }
    }

    /// Returns nil when `task` hasn't finished within `timeout`, without cancelling it.
    private static func result<T: Sendable>(
        of task: Task<T, any Error>,
        within timeout: Duration
    ) async -> Result<T, any Error>? {
        await withCheckedContinuation { continuation in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Result<T, any Error>?, Never>?>(
                initialState: continuation
            )
            let resume: @Sendable (Result<T, any Error>?) -> Void = { result in
                pending.withLock { continuation in
                    continuation?.resume(returning: result)
                    continuation = nil
                }
            }
            let timer = Task {
                try await Task.sleep(for: timeout)
                resume(nil)
            }
            Task {
                resume(await task.result)
                timer.cancel()
            }
        }
    }
}

enum ClaudeCredentialError: LocalizedError, Equatable {
    case keychainPending
    case keychainDenied
    case unreadableLogin
    case invalidLogin
    case expiredLogin

    var errorDescription: String? {
        switch self {
        case .keychainPending:
            "Waiting for Keychain access to Claude Code's login. Unlock the Keychain if macOS asks, then refresh."
        case .keychainDenied:
            "Keychain access to Claude Code's login was denied. Refresh to try again."
        case .unreadableLogin:
            "Cannot read Claude Code's login from the Keychain. Refresh to try again."
        case .invalidLogin:
            "Claude Code's Keychain login is invalid. Sign in again with /login in Claude Code, then refresh."
        case .expiredLogin:
            "Claude Code's access token has expired. Use Claude Code so it can refresh its login, then refresh."
        }
    }
}

/// Keychain access behind a protocol, so tests never read real credentials.
protocol KeychainReading: Sendable {
    /// The generic password stored under `service`, or nil when there is no such item.
    /// May block while macOS asks the user for access.
    func genericPassword(service: String) throws -> Data?
}

enum KeychainError: Error {
    case denied
    case failed
}

/// Reads through Apple's `security` tool, as Claude Code does. Claude Code saves each refreshed
/// token with that tool, which resets the item's partition list to Apple's tools and so
/// revokes any app's "Always Allow". Reading through the same tool never prompts.
struct SystemKeychain: KeychainReading {
    func genericPassword(service: String) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `security` exits with the low byte of the Keychain status.
        switch process.terminationStatus {
        case 0:
            return data.last == UInt8(ascii: "\n") ? data.dropLast() : data
        case errSecItemNotFound & 0xFF:
            return nil
        case errSecUserCanceled & 0xFF, errSecAuthFailed & 0xFF, errSecInteractionNotAllowed & 0xFF:
            throw KeychainError.denied
        default:
            throw KeychainError.failed
        }
    }
}
