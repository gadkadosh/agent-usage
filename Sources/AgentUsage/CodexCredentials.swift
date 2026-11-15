import Foundation

struct ChatGPTCredentials: Sendable {
    let accessToken: String
    let accountID: String?
    var expiresAt: Date? = nil
}

/// Read-only adapter for Codex's file login, verified against rust-v0.163.0.
/// Keychain and in-memory logins are outside this adapter's scope.
struct CodexCredentialSource: Sendable {
    let authURL: URL

    init(authURL: URL = Self.defaultAuthURL()) {
        self.authURL = authURL
    }

    static func defaultAuthURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let directory: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            if override == "~" {
                directory = home
            } else if override.hasPrefix("~/") {
                directory = home.appendingPathComponent(
                    String(override.dropFirst(2)),
                    isDirectory: true
                )
            } else {
                directory = URL(fileURLWithPath: override, isDirectory: true)
            }
        } else {
            directory = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return directory.appendingPathComponent("auth.json")
    }

    func load() throws -> ChatGPTCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw CodexCredentialError.missingLogin
        } catch {
            throw CodexCredentialError.unreadableFile
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let auth = try decoder.decode(AuthFile.self, from: data)
            guard auth.authMode == nil || auth.authMode == "chatgpt" else {
                throw CodexCredentialError.missingLogin
            }
            guard let tokens = auth.tokens else { throw CodexCredentialError.missingLogin }
            let access = tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountID = tokens.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !access.isEmpty, !access.contains(where: \.isWhitespace),
                accountID?.contains(where: \.isWhitespace) != true
            else { throw CodexCredentialError.invalidFile }

            // Decode only expiry, never use JWT claims as proof of authentication.
            // The server validates the token; last_refresh and ID-token expiry are unrelated.
            let parts = access.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
                throw CodexCredentialError.invalidFile
            }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let claimsData = Data(base64Encoded: payload) else {
                throw CodexCredentialError.invalidFile
            }
            let claims = try JSONDecoder().decode(Expiry.self, from: claimsData)
            return ChatGPTCredentials(
                accessToken: access,
                accountID: accountID?.isEmpty == false ? accountID : nil,
                expiresAt: claims.exp.map { Date(timeIntervalSince1970: Double($0)) }
            )
        } catch let error as CodexCredentialError {
            throw error
        } catch {
            // Decoder errors can contain secrets. Never expose them to the UI or logs.
            throw CodexCredentialError.invalidFile
        }
    }

    private struct AuthFile: Decodable {
        let authMode: String?
        let tokens: Tokens?
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let accountId: String?
    }

    private struct Expiry: Decodable {
        let exp: Int64?
    }
}

enum CodexCredentialError: LocalizedError, Equatable {
    case missingLogin
    case unreadableFile
    case invalidFile
    case expiredLogin

    var errorDescription: String? {
        switch self {
        case .missingLogin:
            "No ChatGPT login found in Codex's auth.json or pi. Sign in with codex login or /login in pi, then refresh. Codex Keychain logins aren't supported."
        case .unreadableFile:
            "Cannot read Codex's auth.json. Check its location and file permissions, then refresh."
        case .invalidFile:
            "Codex's auth.json contains invalid ChatGPT credentials. Sign in again with codex login, then refresh."
        case .expiredLogin:
            "Codex's ChatGPT access token has expired. Use Codex to refresh it, or sign in again with codex login, then refresh. Pi fallback requires a valid login for the same account."
        }
    }
}
