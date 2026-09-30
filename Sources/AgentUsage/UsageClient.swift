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

        var isLowRemaining: Bool { remainingFraction <= 0.1 }

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
        guard let token = ProcessInfo.processInfo.environment["OPENAI_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw UsageError.missingToken
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
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

private enum UsageError: LocalizedError {
    case missingToken
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Set OPENAI_ACCESS_TOKEN before starting Agent Usage."
        case .invalidResponse:
            "The usage server returned an invalid response."
        case .httpStatus(401):
            "Access token expired or invalid (HTTP 401)."
        case .httpStatus(let status):
            "Usage request failed (HTTP \(status))."
        }
    }
}
