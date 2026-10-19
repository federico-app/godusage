import Foundation

/// One Claude account: the account UUID plus, when known, the organization whose plan it uses.
/// Plans are org-scoped, so the same account in two orgs is two different usage pools.
struct ClaudeAccountIdentity: Equatable, Hashable, Sendable {
    var accountUUID: String
    var organizationUUID: String?
    var email: String?

    /// Same account, and the same org when both sides name one. A side without an org can't
    /// contradict the other, so it compares on the account alone.
    func isSameAccount(as other: ClaudeAccountIdentity) -> Bool {
        guard accountUUID.lowercased() == other.accountUUID.lowercased() else { return false }
        guard let mine = organizationUUID, let theirs = other.organizationUUID else { return true }
        return mine.lowercased() == theirs.lowercased()
    }

    /// Parses `/api/oauth/profile` (`{"account":{"uuid","email"},"organization":{"uuid"}}`).
    /// `nil` when the body doesn't name an account.
    static func fromProfileResponse(_ body: Data) -> ClaudeAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let uuid = (account["uuid"] as? String)?.nilIfEmpty
        else { return nil }
        let organization = object["organization"] as? [String: Any]
        return ClaudeAccountIdentity(
            accountUUID: uuid,
            organizationUUID: (organization?["uuid"] as? String)?.nilIfEmpty,
            email: (account["email"] as? String)?.nilIfEmpty
        )
    }
}

/// Checks that a Claude token belongs to the account its card is named after (the state file's
/// `oauthAccount`). Claude Code keeps the token and the state file in separate stores, and they can
/// drift apart — e.g. a default home's keychain item holding another home's login — which would
/// otherwise publish one account's usage under another account's name.
///
/// The profile endpoint is called at most once per credential fingerprint: a successful answer is
/// kept for that token, and the card's identity is compared against it on every refresh so a state
/// file change needs no new call. A failed lookup is logged and the usage is published unverified,
/// with a retry after `retryCooldown` — the check must not take down a working card.
@MainActor
final class ClaudeAccountVerifier {
    enum Outcome: Equatable {
        case matches
        /// The token belongs to `tokenAccount`, not the card's account.
        case mismatch(tokenAccount: ClaudeAccountIdentity)
        /// The profile lookup failed; nothing is known about the token's account.
        case unverified
    }

    static let retryCooldown: TimeInterval = 30 * 60

    private let usageClient: ClaudeUsageClient
    private let now: @Sendable () -> Date
    private var known: (fingerprint: Data, account: ClaudeAccountIdentity)?
    private var failed: (fingerprint: Data, retryAt: Date)?

    init(usageClient: ClaudeUsageClient, now: @escaping @Sendable () -> Date) {
        self.usageClient = usageClient
        self.now = now
    }

    /// The outcome for a token without any network call, when its account is already known.
    func cachedOutcome(fingerprint: Data, expected: ClaudeAccountIdentity) -> Outcome? {
        guard let known, known.fingerprint == fingerprint else { return nil }
        return Self.compare(token: known.account, expected: expected)
    }

    func verify(
        accessToken: String,
        fingerprint: Data,
        expected: ClaudeAccountIdentity,
        profileURL: URL
    ) async -> Outcome {
        if let cached = cachedOutcome(fingerprint: fingerprint, expected: expected) {
            return cached
        }
        if let failed, failed.fingerprint == fingerprint, now() < failed.retryAt {
            return .unverified
        }
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchProfile(accessToken: accessToken, profileURL: profileURL)
        } catch {
            return recordFailure(fingerprint: fingerprint, reason: "connection failed")
        }
        guard (200..<300).contains(response.statusCode) else {
            return recordFailure(fingerprint: fingerprint, reason: "HTTP \(response.statusCode)")
        }
        guard let account = ClaudeAccountIdentity.fromProfileResponse(response.body) else {
            return recordFailure(fingerprint: fingerprint, reason: "response names no account")
        }
        known = (fingerprint, account)
        failed = nil
        let outcome = Self.compare(token: account, expected: expected)
        if case .mismatch = outcome {
            AppLog.warn(LogTag.auth("claude"), "token belongs to another account than the state file names; withholding live usage until `claude /login`")
        }
        return outcome
    }

    private func recordFailure(fingerprint: Data, reason: String) -> Outcome {
        AppLog.warn(LogTag.auth("claude"), "account check failed (\(reason)); publishing usage unverified, retrying in \(Int(Self.retryCooldown / 60)) min")
        failed = (fingerprint, now().addingTimeInterval(Self.retryCooldown))
        return .unverified
    }

    private static func compare(token: ClaudeAccountIdentity, expected: ClaudeAccountIdentity) -> Outcome {
        token.isSameAccount(as: expected) ? .matches : .mismatch(tokenAccount: token)
    }
}
