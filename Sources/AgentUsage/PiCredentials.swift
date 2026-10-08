import Foundation

struct PiCredentials: Sendable {
    let accessToken: String
    let accountID: String?
}

/// Reads pi's ChatGPT login without copying, refreshing, or modifying its credentials.
struct PiCredentialSource: Sendable {
    let authURL: URL

    init(authURL: URL = Self.defaultAuthURL()) {
        self.authURL = authURL
    }

    static func defaultAuthURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let directory: URL
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            if override == "~" {
                directory = home
            } else if override.hasPrefix("~/") {
                let relativePath = String(override.dropFirst(2))
                directory = home.appendingPathComponent(relativePath, isDirectory: true)
            } else {
                directory = URL(fileURLWithPath: override, isDirectory: true)
            }
        } else {
            directory = home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
        return directory.appendingPathComponent("auth.json")
    }

    func load(now: Date = Date()) throws -> PiCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw PiCredentialError.missingLogin
        } catch {
            throw PiCredentialError.unreadableFile
        }

        let auth: AuthFile
        do {
            auth = try JSONDecoder().decode(AuthFile.self, from: data)
        } catch {
            // Do not expose decoder errors, which can contain credential values.
            throw PiCredentialError.invalidFile
        }
        guard let entry = auth.codex else { throw PiCredentialError.missingLogin }
        guard entry.type == "oauth" else { throw PiCredentialError.unsupportedLogin }
        guard let access = entry.access?.trimmingCharacters(in: .whitespacesAndNewlines),
            !access.isEmpty, !access.contains(where: { $0.isWhitespace || $0.isNewline }),
            let expires = entry.expires, expires.isFinite
        else {
            throw PiCredentialError.invalidFile
        }
        // Pi stores expiry as Unix milliseconds, not seconds.
        guard expires > now.timeIntervalSince1970 * 1_000 else {
            throw PiCredentialError.expiredLogin
        }
        let accountID = entry.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let accountID, accountID.contains(where: { $0.isWhitespace || $0.isNewline }) {
            throw PiCredentialError.invalidFile
        }
        return PiCredentials(
            accessToken: access,
            accountID: accountID?.isEmpty == false ? accountID : nil
        )
    }

    private struct AuthFile: Decodable {
        let codex: Entry?

        enum CodingKeys: String, CodingKey {
            case codex = "openai-codex"
        }
    }

    private struct Entry: Decodable {
        let type: String
        let access: String?
        let expires: Double?
        let accountId: String?
    }
}

enum PiCredentialError: LocalizedError, Equatable {
    case missingLogin
    case unsupportedLogin
    case unreadableFile
    case invalidFile
    case expiredLogin

    var errorDescription: String? {
        switch self {
        case .missingLogin:
            "No ChatGPT login found in pi. Open pi, run /login, and select OpenAI (ChatGPT Plus/Pro), then refresh."
        case .unsupportedLogin:
            "Pi's OpenAI credentials are not a ChatGPT login. Use /login in pi to connect your ChatGPT subscription, then refresh."
        case .unreadableFile:
            "Cannot read pi's auth.json. Check its location and file permissions, then refresh."
        case .invalidFile:
            "Pi's auth.json contains invalid ChatGPT credentials. Sign in again with /login in pi, then refresh."
        case .expiredLogin:
            "Pi's ChatGPT access token has expired. Use OpenAI in pi to refresh it, or sign in again with /login, then refresh."
        }
    }
}
