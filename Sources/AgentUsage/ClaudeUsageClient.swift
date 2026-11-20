import Foundation

/// The fields Agent Usage reads from Claude's subscription usage endpoint; all others are ignored.
struct ClaudeUsage: Decodable, Sendable {
    let fiveHour: Window
    let sevenDay: Window
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?

    struct Window: Decodable, Sendable {
        /// Percent used, 0–100.
        let utilization: Double
        let resetsAt: Date
    }

    static func decode(_ data: Data) throws -> ClaudeUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Reset times carry microseconds, such as 2026-11-20T21:29:59.591228+00:00.
        // On older macOS, such as 15, the fractional style rejects times without a fraction.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            return try (try? Date(string, strategy: fractional)) ?? Date(string, strategy: .iso8601)
        }
        return try decoder.decode(ClaudeUsage.self, from: data)
    }

    var allowance: Allowance {
        func window(_ window: Window, label: String, title: String, subtitle: String)
            -> AllowanceWindow
        {
            AllowanceWindow(
                label: label,
                title: title,
                subtitle: subtitle,
                usedPercent: window.utilization,
                resetsAt: window.resetsAt
            )
        }
        var windows = [
            window(fiveHour, label: "5h", title: "5-hour window", subtitle: ""),
            window(sevenDay, label: "7d", title: "Weekly window", subtitle: "7 days"),
        ]
        if let sevenDayOpus {
            windows.append(
                window(sevenDayOpus, label: "Opus", title: "Weekly Opus", subtitle: "7 days")
            )
        }
        if let sevenDaySonnet {
            windows.append(
                window(sevenDaySonnet, label: "Sonnet", title: "Weekly Sonnet", subtitle: "7 days")
            )
        }
        return Allowance(windows: windows)
    }
}

extension AllowanceSource {
    static let claude: AllowanceSource = {
        let login = ClaudeLogin()
        return AllowanceSource(provider: .claude) {
            try await ClaudeUsageClient.fetch(login: login, session: .shared)?.allowance
        }
    }()
}

enum ClaudeUsageClient {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Returns nil when Claude Code has no subscription login.
    static func fetch(
        login: ClaudeLogin,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ClaudeUsage? {
        guard let credentials = try await login.credentials(now: now) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        do {
            data = try await UsageRequest.data(for: request, login: .claudeCode, session: session)
        } catch UsageError.rejectedLogin(.claudeCode) {
            await login.discard(credentials)
            throw UsageError.rejectedLogin(.claudeCode)
        }
        do {
            return try ClaudeUsage.decode(data)
        } catch {
            throw UsageError.invalidResponse
        }
    }
}
