import Foundation

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

/// Read-only client for Claude's usage endpoint. Token rotation lives elsewhere and under strict
/// guards (`ClaudeTokenRenewal`): a second process refreshing a still-valid token can trip the
/// server's reuse detection, so only an already-expired token is ever renewed, and the rotated
/// credential is always written back to Claude Code's own store.
struct ClaudeUsageClient: Sendable {
    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    /// `GET /api/oauth/usage`, the plain read Claude Code makes for its own usage display. The User-Agent
    /// matches Claude Code's own `claude-cli/<version> (external, cli)` format.
    func fetchUsage(accessToken: String, usageURL: URL) async throws -> HTTPResponse {
        try await sendUsageRequest(url: usageURL, accessToken: accessToken)
    }

    /// `GET /api/oauth/usage?cedar_ember=1&skip_spend=1`, the exact request Claude Code makes when it checks
    /// for a reset to offer. `cedar_ember=1` opts in to Anthropic's one-off usage-limit reset grants (the
    /// Rate Limit Resets row), which the plain read returns as `null`; `skip_spend=1` drops the spend
    /// figures this request doesn't need. Anthropic rate-limits this variant hard when it's polled, so
    /// the provider asks at most once an hour. Grant eligibility is also decided by client surface: a
    /// User-Agent Anthropic doesn't recognize as Claude Code comes back `eligible: false,
    /// ineligible_reason: "surface"` with no grants.
    func fetchResetGrants(accessToken: String, usageURL: URL) async throws -> HTTPResponse {
        try await sendUsageRequest(url: Self.resetGrantsURL(usageURL), accessToken: accessToken)
    }

    static func resetGrantsURL(_ usageURL: URL) -> URL {
        guard var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false) else { return usageURL }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "cedar_ember", value: "1"),
            URLQueryItem(name: "skip_spend", value: "1")
        ]
        return components.url ?? usageURL
    }

    private func sendUsageRequest(url: URL, accessToken: String) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-cli/2.1.280 (external, cli)"
                ],
                timeout: 10
            )
        )
    }

    /// `GET /api/oauth/profile`, the call Claude Code makes to learn which account and organization a
    /// token belongs to. Read-only; the account check uses it to compare against the card's identity.
    func fetchProfile(accessToken: String, profileURL: URL) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: profileURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-cli/2.1.280 (external, cli)"
                ],
                timeout: 10
            )
        )
    }
}
