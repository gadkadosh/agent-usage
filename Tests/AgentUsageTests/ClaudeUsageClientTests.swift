import Foundation
import XCTest

@testable import AgentUsage

final class ClaudeUsageClientTests: XCTestCase {
    /// Shape verified against a Pro account, with unrelated fields abbreviated.
    private let verified = """
        {
          "five_hour": { "utilization": 24.0, "resets_at": "2026-11-20T21:29:59.591228+00:00" },
          "seven_day": { "utilization": 12.5, "resets_at": "2026-11-25T08:00:00.000412+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "seven_day_oauth_apps": null,
          "iguana_necktie": { "utilization": 99, "resets_at": "not-a-date" },
          "extra_usage": { "is_enabled": false },
          "spend": 1, "limits": []
        }
        """

    func testDecodesMicrosecondResetTimesAndIgnoresOtherFields() throws {
        let allowance = try ClaudeUsage.decode(Data(verified.utf8)).allowance
        XCTAssertEqual(allowance.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(allowance.windows.map(\.title), ["5-hour window", "Weekly window"])
        XCTAssertEqual(
            allowance.windows[0].resetsAt.timeIntervalSince1970,
            1_795_210_199.591228,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            allowance.windows[1].resetsAt.timeIntervalSince1970,
            1_795_593_600.000412,
            accuracy: 0.000001
        )
    }

    func testShowsModelWindowsOnlyWhenPresent() throws {
        let json = """
            {
              "five_hour": { "utilization": 0, "resets_at": "2026-11-20T21:29:59+00:00" },
              "seven_day": { "utilization": 10, "resets_at": "2026-11-25T08:00:00.5+00:00" },
              "seven_day_opus": { "utilization": 40, "resets_at": "2026-11-25T08:00:00.000001+00:00" }
            }
            """
        let allowance = try ClaudeUsage.decode(Data(json.utf8)).allowance
        XCTAssertEqual(allowance.windows.map(\.label), ["5h", "7d", "Opus"])
        XCTAssertEqual(allowance.lowestRemainingFraction, 0.6)
    }

    func testSendsTokenToUsageEndpoint() async throws {
        let login = ClaudeLogin(keychain: FakeKeychain(item: claudeItem()))
        ClaudeUsageProtocol.respond(status: 200, body: verified)
        let usage = try await fetch(login)
        XCTAssertEqual(usage?.allowance.summary, "5h: 76%  7d: 87.5%")
        let request = try XCTUnwrap(ClaudeUsageProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer synthetic-access"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testNoLoginSendsNoRequest() async throws {
        ClaudeUsageProtocol.respond(status: 200, body: verified)
        let usage = try await fetch(ClaudeLogin(keychain: FakeKeychain(item: nil)))
        XCTAssertNil(usage)
        XCTAssertNil(ClaudeUsageProtocol.lastRequest)
    }

    func testRejectedLoginIsRereadOnNextRefresh() async throws {
        let keychain = FakeKeychain(item: claudeItem())
        let login = ClaudeLogin(keychain: keychain)
        ClaudeUsageProtocol.respond(status: 401, body: "{}")
        await assertFailure(login, contains: "Claude Code's login was rejected (HTTP 401)")
        ClaudeUsageProtocol.respond(status: 200, body: verified)
        _ = try await fetch(login)
        XCTAssertEqual(keychain.services.count, 2)
    }

    func testFailuresDoNotExposeResponseBodies() async {
        let login = ClaudeLogin(keychain: FakeKeychain(item: claudeItem()))
        ClaudeUsageProtocol.respond(status: 200, body: #"{"five_hour":"synthetic-secret"}"#)
        await assertFailure(login, contains: "The usage server returned an invalid response.")
        ClaudeUsageProtocol.respond(status: 429, body: "synthetic-secret")
        await assertFailure(login, contains: "HTTP 429")
    }

    override func tearDown() {
        ClaudeUsageProtocol.reset()
    }

    private func fetch(_ login: ClaudeLogin) async throws -> ClaudeUsage? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeUsageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await ClaudeUsageClient.fetch(
            login: login,
            session: session,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func assertFailure(_ login: ClaudeLogin, contains text: String) async {
        do {
            _ = try await fetch(login)
            XCTFail("Expected failure containing \(text)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("synthetic"))
        }
    }
}

/// Intercepts every request. No test can reach the network.
private final class ClaudeUsageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (status: 200, body: "{}")
    nonisolated(unsafe) private static var request: URLRequest?

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static func respond(status: Int, body: String) {
        lock.withLock { response = (status, body) }
    }
    static func reset() { lock.withLock { request = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.request = request
            return Self.response
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
