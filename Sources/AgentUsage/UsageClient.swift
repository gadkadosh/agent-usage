import Foundation

struct UsageLimits: Decodable, Sendable {
    let rateLimit: RateLimit

    /// Paid plans have a 5-hour and a weekly window; the free plan has a single 30-day window.
    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window
        let secondaryWindow: Window?
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAfterSeconds: Int
    }

    static func decode(_ data: Data) throws -> UsageLimits {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageLimits.self, from: data)
    }

    /// Reset countdowns are relative, so anchor them to when the response was received.
    func allowance(receivedAt: Date) -> Allowance {
        let windows = [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap { $0 }
        return Allowance(
            windows: windows.map { window in
                let hours = window.limitWindowSeconds / 3_600
                let days = hours / 24
                let (label, title, subtitle) =
                    switch (hours, days) {
                    case (_, 7): ("7d", "Weekly window", "7 days")
                    case (..<24, _): ("\(hours)h", "\(hours)-hour window", "")
                    default: ("\(days)d", "\(days)-day window", "")
                    }
                return AllowanceWindow(
                    label: label,
                    title: title,
                    subtitle: subtitle,
                    usedPercent: window.usedPercent,
                    resetsAt: receivedAt.addingTimeInterval(TimeInterval(window.resetAfterSeconds))
                )
            }
        )
    }
}

extension AllowanceSource {
    static let chatGPT = AllowanceSource(provider: .chatGPT) {
        try await UsageClient.fetch()?.allowance(receivedAt: Date())
    }
}

enum UsageClient {
    /// Returns nil when neither Codex nor pi has a ChatGPT login.
    static func fetch() async throws -> UsageLimits? {
        try await fetch(codex: CodexCredentialSource(), pi: PiCredentialSource(), session: .shared)
    }

    static func fetch(
        codex: CodexCredentialSource,
        pi: PiCredentialSource,
        session: URLSession,
        now: Date = Date()
    ) async throws -> UsageLimits? {
        let preferred: ChatGPTCredentials
        do {
            preferred = try codex.load()
        } catch CodexCredentialError.missingLogin {
            let fallback: ChatGPTCredentials
            do {
                fallback = try pi.load(now: now)
            } catch PiCredentialError.missingLogin {
                return nil
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
        let data = try await UsageRequest.data(for: request, login: source, session: session)
        do {
            return try UsageLimits.decode(data)
        } catch {
            // Decoder errors are developer text, such as "the data is missing". Never show them.
            throw UsageError.invalidResponse
        }
    }
}

enum LoginSource {
    case codex
    case pi
    case claudeCode
}

/// Request rules shared by every unofficial usage endpoint.
enum UsageRequest {
    static func data(
        for request: URLRequest,
        login: LoginSource,
        session: URLSession
    ) async throws -> Data {
        var request = request
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
        if status == 401 { throw UsageError.rejectedLogin(login) }
        guard (200..<300).contains(status) else {
            throw UsageError.httpStatus(status)
        }
        return data
    }
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

enum UsageError: LocalizedError {
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
        case .rejectedLogin(.claudeCode):
            "Claude Code's login was rejected (HTTP 401). Use Claude Code or sign in again with /login, then refresh."
        case .httpStatus(let status):
            "Usage request failed (HTTP \(status))."
        }
    }
}
