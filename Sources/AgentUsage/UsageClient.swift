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

        var remainingFraction: Double {
            min(1, max(0, (100 - usedPercent) / 100))
        }

        var meterOpacity: Double { 0.65 + 0.35 * remainingFraction }

        var remaining: String {
            String(format: "%g", remainingFraction * 100) + "%"
        }

        var resetIn: String {
            let seconds = max(0, resetAfterSeconds)
            if seconds < 60 { return "\(seconds)s" }
            if seconds < 3_600 { return "\(seconds / 60)m" }
            if seconds < 86_400 { return "\(seconds / 3_600)h\((seconds % 3_600) / 60)m" }
            return "\(seconds / 86_400)d\((seconds % 86_400) / 3_600)h"
        }
    }

    var summary: String {
        "5h: \(rateLimit.primaryWindow.remaining)  7d: \(rateLimit.secondaryWindow.remaining)"
    }

    var details: String {
        "\(summary) | 5h: \(rateLimit.primaryWindow.resetIn)  7d: \(rateLimit.secondaryWindow.resetIn)"
    }
}

enum UsageClient {
    static func fetch() async throws -> UsageLimits {
        try await fetch(credentials: PiCredentialSource(), session: .shared)
    }

    static func fetch(credentials: PiCredentialSource, session: URLSession) async throws
        -> UsageLimits
    {
        let credentials = try credentials.load()

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
        guard (200..<300).contains(status) else {
            throw UsageError.httpStatus(status)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageLimits.self, from: data)
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

private enum UsageError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The usage server returned an invalid response."
        case .httpStatus(401):
            "Pi's ChatGPT login was rejected (HTTP 401). Use OpenAI in pi or sign in again with /login, then refresh."
        case .httpStatus(let status):
            "Usage request failed (HTTP \(status))."
        }
    }
}
