import Foundation
import XCTest

@testable import AgentUsage

final class CodexCredentialsTests: XCTestCase {
    func testDefaultAndCustomDirectories() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(
            CodexCredentialSource.defaultAuthURL(home: home, environment: [:]).path,
            "/Users/test/.codex/auth.json"
        )
        for (override, expected) in [
            ("/tmp/custom-codex", "/tmp/custom-codex/auth.json"),
            ("~/custom-codex", "/Users/test/custom-codex/auth.json"),
            ("~", "/Users/test/auth.json"),
            ("", "/Users/test/.codex/auth.json"),
        ] {
            XCTAssertEqual(
                CodexCredentialSource.defaultAuthURL(
                    home: home,
                    environment: ["CODEX_HOME": override]
                ).path,
                expected
            )
        }
    }

    func testReadsAccessTokenExpiryAndAccountWithoutModifyingFile() throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        let token = try fixture.writeCodex(expiry: 1_700_000_000)
        let before = try Data(contentsOf: fixture.codex.authURL)
        let credentials = try fixture.codex.load()
        XCTAssertEqual(credentials.accessToken, token)
        XCTAssertEqual(credentials.accountID, "test-account")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try Data(contentsOf: fixture.codex.authURL), before)
    }

    func testLegacyLoginAndRotationWithoutAccountOrExpiry() throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        let token = try fixture.writeCodex(account: nil, expiry: nil, mode: nil)
        let credentials = try fixture.codex.load()
        XCTAssertEqual(credentials.accessToken, token)
        XCTAssertNil(credentials.accountID)
        XCTAssertNil(credentials.expiresAt)
        let rotated = try fixture.writeCodex(status: 401)
        XCTAssertEqual(try fixture.codex.load().accessToken, rotated)
        try Data("{}".utf8).write(to: fixture.codex.authURL)
        XCTAssertThrowsError(try fixture.codex.load()) {
            XCTAssertEqual($0 as? CodexCredentialError, .missingLogin)
        }
    }

    func testMissingAndAPIKeyLoginsAreNotSubscriptionCredentials() throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.codex.load()) {
            XCTAssertEqual($0 as? CodexCredentialError, .missingLogin)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.codex.authURL.path))
        for json in ["{}", #"{"OPENAI_API_KEY":"synthetic-secret"}"#] {
            try Data(json.utf8).write(to: fixture.codex.authURL)
            XCTAssertThrowsError(try fixture.codex.load()) {
                XCTAssertEqual($0 as? CodexCredentialError, .missingLogin)
            }
        }
        // An explicitly selected API login must not use leftover subscription tokens.
        _ = try fixture.writeCodex(mode: "apikey")
        XCTAssertThrowsError(try fixture.codex.load()) {
            XCTAssertEqual($0 as? CodexCredentialError, .missingLogin)
        }
    }

    func testInvalidAndUnreadableFilesHaveSanitizedErrors() throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        let invalidJWT = try syntheticCodexToken(expiry: "synthetic-secret")
        let validJWT = try syntheticCodexToken()
        for json in [
            "synthetic-secret", "[]",
            #"{"tokens":{}}"#,
            #"{"tokens":{"access_token":42}}"#,
            #"{"tokens":{"access_token":"  "}}"#,
            #"{"tokens":{"access_token":"a.b.c"}}"#,
            #"{"tokens":{"access_token":"synthetic\r\nsecret"}}"#,
            "{\"tokens\":{\"access_token\":\"\(invalidJWT)\"}}",
            "{\"tokens\":{\"access_token\":\"\(validJWT)\",\"account_id\":\"bad\\r\\nsecret\"}}",
        ] {
            try Data(json.utf8).write(to: fixture.codex.authURL)
            XCTAssertThrowsError(try fixture.codex.load()) {
                XCTAssertEqual($0 as? CodexCredentialError, .invalidFile)
                XCTAssertFalse($0.localizedDescription.contains("synthetic-secret"))
            }
        }
        try FileManager.default.removeItem(at: fixture.codex.authURL)
        try FileManager.default.createDirectory(
            at: fixture.codex.authURL,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try fixture.codex.load()) {
            XCTAssertEqual($0 as? CodexCredentialError, .unreadableFile)
        }
    }
}

@MainActor
final class AllowanceCredentialSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCodexWinsAndRereadsRotationOnEachRefresh() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        try fixture.writePi(account: "another-account")
        _ = try fixture.writeCodex(percent: 10)
        try await assertPercent(fixture, expected: 10)
        _ = try fixture.writeCodex(percent: 35)
        try await assertPercent(fixture, expected: 35)
        // A preferred login must also work without readable pi credentials.
        try Data("not-json".utf8).write(to: fixture.pi.authURL)
        try await assertPercent(fixture, expected: 35)
    }

    func testMissingCodexOrAPIKeyLoginUsesPi() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        try fixture.writePi()
        try await assertPercent(fixture, expected: 20)
        _ = try fixture.writeCodex(mode: "apikey")
        try await assertPercent(fixture, expected: 20)
        try Data("{}".utf8).write(to: fixture.codex.authURL)
        try await assertPercent(fixture, expected: 20)
    }

    func testExpiredOrRejectedCodexUsesPiForSameAccountOnly() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        try fixture.writePi()
        let before = try Data(contentsOf: fixture.pi.authURL)
        for expiry in [1_699_999_999, 1_700_000_000] {
            _ = try fixture.writeCodex(expiry: expiry)
            try await assertPercent(fixture, expected: 20)
        }
        _ = try fixture.writeCodex(status: 401)
        try await assertPercent(fixture, expected: 20)
        XCTAssertEqual(try Data(contentsOf: fixture.pi.authURL), before)
    }

    func testFallbackCannotChangeOrGuessAccountAfterExpiryOrRejection() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        for (codexAccount, piAccount) in [
            ("test-account", "another-account"),
            (nil, "test-account"),
            ("test-account", nil),
            (nil, nil),
        ] as [(String?, String?)] {
            try fixture.writePi(account: piAccount)
            _ = try fixture.writeCodex(account: codexAccount, expiry: 1_700_000_000)
            await assertFailure(fixture, contains: "expired")
            _ = try fixture.writeCodex(account: codexAccount, status: 401)
            await assertFailure(fixture, contains: "Codex's ChatGPT login was rejected (HTTP 401)")
        }
    }

    func testUnavailablePiKeepsCodexRecoveryInstructions() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        for piContent in [nil, "{}", "not-json"] as [String?] {
            if let piContent { try Data(piContent.utf8).write(to: fixture.pi.authURL) }
            _ = try fixture.writeCodex(status: 401)
            await assertFailure(fixture, contains: "codex login")
            _ = try fixture.writeCodex(expiry: 1_700_000_000)
            await assertFailure(fixture, contains: "expired")
        }
        try fixture.writePi(expiry: 1_700_000_000_000)
        _ = try fixture.writeCodex(status: 401)
        await assertFailure(fixture, contains: "codex login")
    }

    func testOtherFailuresDoNotTryPi() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        try fixture.writePi()
        for status in [403, 429, 500] {
            _ = try fixture.writeCodex(status: status)
            await assertFailure(fixture, contains: "HTTP \(status)")
        }
        _ = try fixture.writeCodex(status: -1)
        do {
            _ = try await fetch(fixture)
            XCTFail("Expected the network error to be preserved")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        try Data("not-json".utf8).write(to: fixture.codex.authURL)
        await assertFailure(fixture, contains: "invalid ChatGPT credentials")
        try FileManager.default.removeItem(at: fixture.codex.authURL)
        try FileManager.default.createDirectory(
            at: fixture.codex.authURL,
            withIntermediateDirectories: false
        )
        await assertFailure(fixture, contains: "Cannot read Codex")
    }

    func testNoLoginsExplainsBothSources() async throws {
        let fixture = try AllowanceAuthFixture()
        defer { fixture.remove() }
        await assertFailure(fixture, contains: "codex login or /login in pi")
    }

    private func fetch(_ fixture: AllowanceAuthFixture) async throws -> UsageLimits {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AllowanceSelectionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await UsageClient.fetch(
            codex: fixture.codex,
            pi: fixture.pi,
            session: session,
            now: now
        )
    }

    private func assertPercent(
        _ fixture: AllowanceAuthFixture,
        expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await fetch(fixture)
        XCTAssertEqual(result.rateLimit.primaryWindow.usedPercent, expected, file: file, line: line)
    }

    private func assertFailure(_ fixture: AllowanceAuthFixture, contains text: String) async {
        do {
            _ = try await fetch(fixture)
            XCTFail("Expected failure containing \(text)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
        }
    }
}

private struct AllowanceAuthFixture {
    let directory: URL
    var codex: CodexCredentialSource {
        CodexCredentialSource(authURL: directory.appendingPathComponent("codex-auth.json"))
    }
    var pi: PiCredentialSource {
        PiCredentialSource(authURL: directory.appendingPathComponent("pi-auth.json"))
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writeCodex(
        account: String? = "test-account",
        expiry: Int? = 4_102_444_800,
        status: Int = 200,
        percent: Int = 10,
        mode: String? = "chatgpt"
    ) throws -> String {
        let access = try syntheticCodexToken(
            expiry: expiry,
            status: status,
            percent: percent,
            account: account
        )
        var tokens: [String: Any] = [
            "access_token": access, "id_token": "unused-id-token",
            "refresh_token": "unused-refresh-token",
        ]
        tokens["account_id"] = account
        var json: [String: Any] = ["tokens": tokens, "last_refresh": "2020-01-01T00:00:00Z"]
        json["auth_mode"] = mode
        try JSONSerialization.data(withJSONObject: json).write(to: codex.authURL)
        return access
    }

    func writePi(account: String? = "test-account", expiry: Int = 4_102_444_800_000) throws {
        var entry: [String: Any] = ["type": "oauth", "access": "pi-access", "expires": expiry]
        entry["accountId"] = account
        try JSONSerialization.data(withJSONObject: ["openai-codex": entry]).write(to: pi.authURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func syntheticCodexToken(
    expiry: Any? = 4_102_444_800,
    status: Int = 200,
    percent: Int = 10,
    account: String? = "test-account"
) throws -> String {
    var claims: [String: Any] = ["status": status, "percent": percent]
    claims["exp"] = expiry
    claims["account"] = account
    let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "synthetic.\(payload).signature"
}

/// Intercepts every request. No test can reach the network or real credentials.
private final class AllowanceSelectionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        var status = 200
        var percent = 20
        if token != "pi-access" {
            let parts = token.split(separator: ".")
            guard parts.count == 3 else {
                XCTFail("Unexpected access token")
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            let data = Data(base64Encoded: payload)!
            let claims = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "ChatGPT-Account-Id"),
                claims["account"] as? String
            )
            status = claims["status"] as! Int
            percent = claims["percent"] as! Int
        } else {
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
        }
        if status == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data(
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"reset_after_seconds\":60},\"secondary_window\":{\"used_percent\":30,\"reset_after_seconds\":120}}}"
                .utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
