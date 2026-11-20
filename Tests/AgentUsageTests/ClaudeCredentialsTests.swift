import Foundation
import XCTest

@testable import AgentUsage

final class ClaudeCredentialsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testReadsOnlyTokenAndMillisecondExpiry() throws {
        let credentials = try ClaudeCredentials.parse(claudeItem(expiresAt: 1_700_003_600_000))
        XCTAssertEqual(
            credentials,
            ClaudeCredentials(
                accessToken: "synthetic-access",
                expiresAt: Date(timeIntervalSince1970: 1_700_003_600)
            )
        )
    }

    func testItemWithoutSubscriptionLoginIsSignedOut() throws {
        XCTAssertNil(try ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)))
    }

    func testInvalidItemsHaveSanitizedErrors() {
        for json in [
            "synthetic-secret", "[]",
            #"{"claudeAiOauth":{"expiresAt":1}}"#,
            #"{"claudeAiOauth":{"accessToken":"synthetic-secret"}}"#,
            #"{"claudeAiOauth":{"accessToken":"  ","expiresAt":1}}"#,
            #"{"claudeAiOauth":{"accessToken":"synthetic\r\nsecret","expiresAt":1}}"#,
            #"{"claudeAiOauth":{"accessToken":42,"expiresAt":"synthetic-secret"}}"#,
        ] {
            XCTAssertThrowsError(try ClaudeCredentials.parse(Data(json.utf8))) {
                XCTAssertEqual($0 as? ClaudeCredentialError, .invalidLogin)
                XCTAssertFalse($0.localizedDescription.contains("synthetic"))
            }
        }
    }

    func testMissingItemIsSignedOutWithoutError() async throws {
        let keychain = FakeKeychain(item: nil)
        let credentials = try await ClaudeLogin(keychain: keychain).credentials(now: now)
        XCTAssertNil(credentials)
        XCTAssertEqual(keychain.services, [ClaudeLogin.service])
    }

    func testKeepsTokenUntilExpiryThenRereads() async throws {
        let keychain = FakeKeychain(item: claudeItem(token: "first", expiresAt: 1_700_000_060_000))
        let login = ClaudeLogin(keychain: keychain)
        let first = try await login.credentials(now: now)
        let again = try await login.credentials(now: now.addingTimeInterval(59))
        XCTAssertEqual(first?.accessToken, "first")
        XCTAssertEqual(again, first)
        XCTAssertEqual(keychain.services.count, 1)

        keychain.item = claudeItem(token: "second", expiresAt: 1_700_000_120_000)
        let rotated = try await login.credentials(now: now.addingTimeInterval(60))
        XCTAssertEqual(rotated?.accessToken, "second")
        XCTAssertEqual(keychain.services.count, 2)
    }

    func testDiscardedTokenIsReread() async throws {
        let keychain = FakeKeychain(item: claudeItem())
        let login = ClaudeLogin(keychain: keychain)
        let credentials = try await login.credentials(now: now)
        await login.discard(try XCTUnwrap(credentials))
        _ = try await login.credentials(now: now)
        XCTAssertEqual(keychain.services.count, 2)
    }

    func testExpiredLoginAsksToUseClaudeCode() async {
        let keychain = FakeKeychain(item: claudeItem(expiresAt: 1_700_000_000_000))
        await assertError(ClaudeLogin(keychain: keychain), .expiredLogin)
        XCTAssertTrue(
            ClaudeCredentialError.expiredLogin.localizedDescription.contains("Use Claude Code")
        )
    }

    func testKeychainFailuresAreSanitized() async {
        let keychain = FakeKeychain(item: nil)
        keychain.error = KeychainError.denied
        await assertError(ClaudeLogin(keychain: keychain), .keychainDenied)
        keychain.error = URLError(
            .unknown,
            userInfo: [NSLocalizedDescriptionKey: "synthetic-secret"]
        )
        await assertError(ClaudeLogin(keychain: keychain), .unreadableLogin)
    }

    func testPendingAccessPromptIsBoundedAndNeverStacked() async throws {
        let keychain = FakeKeychain(item: claudeItem())
        keychain.blocked = true
        let login = ClaudeLogin(keychain: keychain, timeout: .milliseconds(50))
        await assertError(login, .keychainPending)
        await assertError(login, .keychainPending)
        XCTAssertEqual(keychain.services.count, 1, "A pending prompt must not start another read")

        keychain.release()
        try await Task.sleep(for: .milliseconds(100))
        let credentials = try await login.credentials(now: now)
        XCTAssertEqual(credentials?.accessToken, "synthetic-access")
        XCTAssertEqual(keychain.services.count, 1)
    }

    private func assertError(
        _ login: ClaudeLogin,
        _ expected: ClaudeCredentialError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await login.credentials(now: now)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeCredentialError, expected, file: file, line: line)
        }
    }
}

func claudeItem(
    token: String = "synthetic-access",
    expiresAt: Double = 4_102_444_800_000
) -> Data {
    let item: [String: Any] = [
        "claudeAiOauth": [
            "accessToken": token, "expiresAt": expiresAt,
            "refreshToken": "unused-refresh-token", "subscriptionType": "pro",
            "scopes": ["user:inference", "user:profile"],
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: item)
}

/// Stands in for the macOS Keychain; tests never read real credentials.
final class FakeKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var _item: Data?
    private var _services: [String] = []
    private var _error: (any Error)?
    /// Simulates a macOS access prompt the user hasn't answered.
    var blocked = false

    init(item: Data?) { _item = item }

    var item: Data? {
        get { lock.withLock { _item } }
        set { lock.withLock { _item = newValue } }
    }
    var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var services: [String] { lock.withLock { _services } }

    func release() { gate.signal() }

    func genericPassword(service: String) throws -> Data? {
        let blocked = lock.withLock {
            _services.append(service)
            return self.blocked
        }
        if blocked { gate.wait() }
        if let error { throw error }
        return item
    }
}
