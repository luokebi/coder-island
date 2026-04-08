import Foundation

/// Codex usage fetcher that mirrors the approach used by CodexBar
/// (steipete/CodexBar). Reads `~/.codex/auth.json` directly — a plain
/// JSON file written by the Codex CLI when the user logs in — to get
/// the OAuth access token and account id, then calls the ChatGPT
/// backend's `/wham/usage` endpoint with `Authorization: Bearer <token>`.
///
/// **No keychain access required** — the credential is in a regular
/// home-directory file the user already trusts the Codex CLI to manage.
/// **No PTY scraping required** — we just hit the same API the
/// `/status` slash command renders inside the TUI.
enum CodexOAuthUsageFetcher {
    /// Default ChatGPT backend base URL. Codex's config supports
    /// overriding `chatgpt_base_url` in `~/.codex/config.toml`; we
    /// honor that override the same way CodexBar does.
    private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api"
    private static let usagePath = "/wham/usage"

    enum FetchError: Error {
        case noAuthFile
        case missingTokens
        case unauthorized
        case httpError(Int)
        case decodeFailed
        case network(Error)
    }

    /// Snapshot of just the fields the UI needs.
    struct UsageSnapshot {
        let primaryUsedPercent: Int?
        let primaryResetAt: Date?
        let primaryWindowSeconds: Int?
        let secondaryUsedPercent: Int?
        let secondaryResetAt: Date?
        let secondaryWindowSeconds: Int?
        let planType: String?
    }

    static func fetch() async throws -> UsageSnapshot {
        let creds = try loadCredentials()
        return try await fetchUsage(
            accessToken: creds.accessToken,
            accountId: creds.accountId
        )
    }

    // MARK: - Credentials

    struct Credentials {
        let accessToken: String
        let accountId: String?
    }

    private static func loadCredentials() throws -> Credentials {
        let url = codexHome().appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FetchError.noAuthFile
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.missingTokens
        }
        // Some users have a legacy `OPENAI_API_KEY` top-level entry —
        // CodexBar treats that as a usable token. We do too.
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Credentials(accessToken: apiKey, accountId: nil)
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw FetchError.missingTokens
        }
        let accountId = tokens["account_id"] as? String
        return Credentials(accessToken: accessToken, accountId: accountId)
    }

    /// Honor the `$CODEX_HOME` env var if set, otherwise default to
    /// `~/.codex` — the same convention the Codex CLI uses.
    private static func codexHome() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    // MARK: - HTTP

    private static func fetchUsage(
        accessToken: String,
        accountId: String?
    ) async throws -> UsageSnapshot {
        let baseURL = resolveBaseURL()
        guard let url = URL(string: baseURL + usagePath) else {
            throw FetchError.network(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CoderIsland", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.decodeFailed
        }
        switch http.statusCode {
        case 200...299:
            return try parseResponse(data)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.httpError(http.statusCode)
        }
    }

    /// Read `chatgpt_base_url` from `~/.codex/config.toml` if set,
    /// otherwise return the hard-coded default. Naive TOML parser —
    /// only handles `key = "value"` lines, which is all we need.
    private static func resolveBaseURL() -> String {
        let configURL = codexHome().appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let contents = try? String(contentsOf: configURL, encoding: .utf8)
        else {
            return defaultChatGPTBaseURL
        }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasSuffix("/") { value = String(value.dropLast()) }
            // CodexBar normalizes chatgpt.com → chatgpt.com/backend-api.
            if (value.hasPrefix("https://chatgpt.com")
                || value.hasPrefix("https://chat.openai.com"))
                && !value.contains("/backend-api")
            {
                value += "/backend-api"
            }
            return value
        }
        return defaultChatGPTBaseURL
    }

    private static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed
        }
        let planType = json["plan_type"] as? String
        let rate = json["rate_limit"] as? [String: Any]
        let primary = (rate?["primary_window"] as? [String: Any])
        let secondary = (rate?["secondary_window"] as? [String: Any])

        func date(_ dict: [String: Any]?) -> Date? {
            if let v = dict?["reset_at"] as? Double {
                return Date(timeIntervalSince1970: v)
            }
            if let v = dict?["reset_at"] as? Int {
                return Date(timeIntervalSince1970: TimeInterval(v))
            }
            return nil
        }

        return UsageSnapshot(
            primaryUsedPercent: primary?["used_percent"] as? Int,
            primaryResetAt: date(primary),
            primaryWindowSeconds: primary?["limit_window_seconds"] as? Int,
            secondaryUsedPercent: secondary?["used_percent"] as? Int,
            secondaryResetAt: date(secondary),
            secondaryWindowSeconds: secondary?["limit_window_seconds"] as? Int,
            planType: planType
        )
    }
}
