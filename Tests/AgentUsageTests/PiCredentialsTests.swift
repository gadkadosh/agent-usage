import Foundation
import XCTest
@testable import AgentUsage

final class PiCredentialsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDefaultPathDoesNotRequireEnvironment() {
        let url = PiCredentialSource.defaultAuthURL(home: URL(fileURLWithPath: "/Users/test"), environment: [:])
        XCTAssertEqual(url.path, "/Users/test/.pi/agent/auth.json")
    }

    func testCustomPiDirectoryAndTildeExpansion() {
        let home = URL(fileURLWithPath: "/Users/test")
        for (override, expected) in [
            ("/tmp/custom-pi", "/tmp/custom-pi/auth.json"),
            ("~/custom-pi", "/Users/test/custom-pi/auth.json"),
            ("~", "/Users/test/auth.json"),
            ("", "/Users/test/.pi/agent/auth.json")
        ] {
            let url = PiCredentialSource.defaultAuthURL(home: home, environment: ["PI_CODING_AGENT_DIR": override])
            XCTAssertEqual(url.path, expected)
        }
    }

    func testReadsOnlyChatGPTCredentialsAndLeavesFileUnchanged() throws {
        let content = #"{"openai-codex":{"type":"oauth","access":"test-access","refresh":"test-refresh","expires":1700000001000,"accountId":"test-account"},"openai":{"type":"api_key","key":"not-a-subscription"},"other-provider":42}"#
        let fixture = try AuthFixture(content)
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.url)

        let credentials = try fixture.source.load(now: now)

        XCTAssertEqual(credentials.accessToken, "test-access")
        XCTAssertEqual(credentials.accountID, "test-account")
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testLegacyEntryWithoutAccountIDOrRefreshToken() throws {
        let fixture = try AuthFixture(#"{"openai-codex":{"type":"oauth","access":"test-access","expires":1700000001000}}"#)
        defer { fixture.remove() }
        XCTAssertNil(try fixture.source.load(now: now).accountID)
    }

    func testMissingFileDoesNotCreateCredentials() throws {
        let fixture = try AuthFixture(nil)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.source.load(now: now)) {
            XCTAssertEqual($0 as? PiCredentialError, .missingLogin)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testMissingLoginAndAPIKeyAreNotUsedAsFallbacks() throws {
        try assertError(.missingLogin, content: #"{"openai":{"type":"api_key","key":"test-key"}}"#)
        try assertError(.missingLogin, content: "{}")
        try assertError(.unsupportedLogin, content: #"{"openai-codex":{"type":"api_key","key":"test-key"}}"#)
    }

    func testExpiredAndExactlyExpiringTokens() throws {
        for expiry in [1_699_999_999_000, 1_700_000_000_000] {
            try assertError(.expiredLogin, content: "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"test-access\",\"expires\":\(expiry)}}")
        }
    }

    func testInvalidCredentialsHaveSanitizedErrors() throws {
        for content in [
            "not-json-secret-value", "[]",
            #"{"openai-codex":{"type":"oauth"}}"#,
            #"{"openai-codex":{"type":"oauth","access":"  ","expires":1700000001000}}"#,
            #"{"openai-codex":{"type":"oauth","access":123,"expires":1700000001000}}"#,
            #"{"openai-codex":{"type":"oauth","access":"test-access","expires":"secret-value"}}"#,
            #"{"openai-codex":{"type":"oauth","access":"test\r\nsecret-value","expires":1700000001000}}"#,
            #"{"openai-codex":{"type":"oauth","access":"test-access","expires":1700000001000,"accountId":"test\r\nsecret-value"}}"#
        ] {
            try assertError(.invalidFile, content: content)
        }
        XCTAssertFalse(PiCredentialError.invalidFile.localizedDescription.contains("secret-value"))
    }

    func testUnreadableFileHasDistinctError() throws {
        let fixture = try AuthFixture(nil)
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixture.source.load(now: now)) {
            XCTAssertEqual($0 as? PiCredentialError, .unreadableFile)
        }
    }

    func testReloadsRotatedCredentialsAndDetectsLogout() throws {
        let fixture = try AuthFixture(validAuth(access: "first"))
        defer { fixture.remove() }
        let source = fixture.source
        XCTAssertEqual(try source.load(now: now).accessToken, "first")
        try fixture.write(validAuth(access: "second"))
        XCTAssertEqual(try source.load(now: now).accessToken, "second")
        try fixture.write("{}")
        XCTAssertThrowsError(try source.load(now: now)) {
            XCTAssertEqual($0 as? PiCredentialError, .missingLogin)
        }
    }

    private func assertError(_ error: PiCredentialError, content: String) throws {
        let fixture = try AuthFixture(content)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.source.load(now: now)) {
            XCTAssertEqual($0 as? PiCredentialError, error)
        }
    }
}

@MainActor
final class PiUsageClientTests: XCTestCase {
    func testFetchUsesPiTokenAndAccountAndRereadsOnNextRequest() async throws {
        let fixture = try AuthFixture(validAuth(access: "first"))
        defer { fixture.remove() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PiUsageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let first = try await UsageClient.fetch(credentials: fixture.source, session: session)
        XCTAssertEqual(first.rateLimit.primaryWindow.usedPercent, 10)
        try fixture.write(validAuth(access: "second"))
        let second = try await UsageClient.fetch(credentials: fixture.source, session: session)
        XCTAssertEqual(second.rateLimit.primaryWindow.usedPercent, 20)

        try fixture.write(validAuth(access: "rejected"))
        do {
            _ = try await UsageClient.fetch(credentials: fixture.source, session: session)
            XCTFail("Expected a rejected login")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertTrue(error.localizedDescription.contains("pi"))
            XCTAssertTrue(error.localizedDescription.contains("/login"))
        }
    }
}

private struct AuthFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("auth.json") }
    var source: PiCredentialSource { PiCredentialSource(authURL: url) }

    init(_ content: String?) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let content { try write(content) }
    }

    func write(_ content: String) throws {
        try Data(content.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func validAuth(access: String) -> String {
    // Synthetic credentials, valid until 2100. Never use the developer's real auth store in tests.
    "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"\(access)\",\"expires\":4102444800000,\"accountId\":\"test-account\"}}"
}

private final class PiUsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(["Bearer first", "Bearer second", "Bearer rejected"].contains(authorization))
        let status = authorization == "Bearer rejected" ? 401 : 200
        let percent = authorization == "Bearer first" ? 10 : 20
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"reset_after_seconds\":60},\"secondary_window\":{\"used_percent\":30,\"reset_after_seconds\":120}}}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
