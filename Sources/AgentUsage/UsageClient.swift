import Foundation

struct UsageLimits: Decodable, Sendable {
    let rateLimit: RateLimit

    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window
        let secondaryWindow: Window
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let resetAfterSeconds: Int
    }

    /// Reset countdowns are relative, so anchor them to when the response was received.
    func allowance(receivedAt: Date) -> Allowance {
        func window(_ window: Window, label: String, title: String, subtitle: String)
            -> AllowanceWindow
        {
            AllowanceWindow(
                label: label,
                title: title,
                subtitle: subtitle,
                usedPercent: window.usedPercent,
                resetsAt: receivedAt.addingTimeInterval(TimeInterval(window.resetAfterSeconds))
            )
        }
        return Allowance(windows: [
            window(rateLimit.primaryWindow, label: "5h", title: "5-hour window", subtitle: ""),
            window(
                rateLimit.secondaryWindow,
                label: "7d",
                title: "Weekly window",
                subtitle: "7 days"
            ),
        ])
    }
}

extension AllowanceSource {
    static let chatGPT = AllowanceSource(provider: .chatGPT) {
        try await UsageClient.fetch().allowance(receivedAt: Date())
    }
}

enum UsageClient {
    static func fetch() async throws -> UsageLimits {
        try await fetch(codex: CodexCredentialSource(), pi: PiCredentialSource(), session: .shared)
    }

    static func fetch(
        codex: CodexCredentialSource,
        pi: PiCredentialSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> UsageLimits {
        let preferred: ChatGPTCredentials
        do {
            preferred = try codex.load()
        } catch CodexCredentialError.missingLogin {
            let fallback: ChatGPTCredentials
            do {
                fallback = try pi.load(now: now)
            } catch PiCredentialError.missingLogin {
                throw CodexCredentialError.missingLogin
            }
            return try await fetch(credentials: fallback, source: .pi, session: session)
        }

        if let expiry = preferred.expiresAt, expiry <= now {
            guard let fallback = sameAccountFallback(for: preferred, pi: pi, now: now) else {
                throw CodexCredentialError.expiredLogin
            }
            return try await fetch(credentials: fallback, source: .pi, session: session)
        }

        do {
            return try await fetch(credentials: preferred, source: .codex, session: session)
        } catch UsageError.rejectedLogin(.codex) {
            guard let fallback = sameAccountFallback(for: preferred, pi: pi, now: now) else {
                throw UsageError.rejectedLogin(.codex)
            }
            return try await fetch(credentials: fallback, source: .pi, session: session)
        }
    }

    private static func sameAccountFallback(
        for preferred: ChatGPTCredentials,
        pi: PiCredentialSource,
        now: Date
    ) -> ChatGPTCredentials? {
        guard let accountID = preferred.accountID,
            let fallback = try? pi.load(now: now),
            fallback.accountID == accountID,
            fallback.accessToken != preferred.accessToken
        else { return nil }
        return fallback
    }

    private static func fetch(
        credentials: ChatGPTCredentials,
        source: LoginSource,
        session: URLSession
    ) async throws -> UsageLimits {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await session.data(
            for: request,
            delegate: RejectUsageRedirects()
        )
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw UsageError.invalidResponse
        }
        if status == 401 { throw UsageError.rejectedLogin(source) }
        guard (200..<300).contains(status) else {
            throw UsageError.httpStatus(status)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageLimits.self, from: data)
    }
}

private enum LoginSource {
    case codex
    case pi
}

/// Apply the policy per request, including when a caller injects a session.
private final class RejectUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Keep authenticated requests at the original endpoint, even for same-host redirects.
        completionHandler(nil)
    }
}

private enum UsageError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case rejectedLogin(LoginSource)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The usage server returned an invalid response."
        case .rejectedLogin(.codex):
            "Codex's ChatGPT login was rejected (HTTP 401). Use Codex or sign in again with codex login, then refresh. Pi fallback requires a valid login for the same account."
        case .rejectedLogin(.pi):
            "Pi's ChatGPT login was rejected (HTTP 401). Use OpenAI in pi or sign in again with /login, then refresh."
        case .httpStatus(let status):
            "Usage request failed (HTTP \(status))."
        }
    }
}
