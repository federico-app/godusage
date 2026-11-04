import Foundation

/// The fingerprint a Claude or Codex quota window goes up under, from the account the login belongs
/// to, so the same account read on several Macs is one account in a team's Plans report. Only the
/// hash leaves the Mac. Nil when the login names no account: the window is then named by the Mac and
/// its card, and the report warns that it may count one account more than once.
///
/// Usage rows never take this key: two members on one Claude or Codex account each upload the usage
/// of their own Mac's logs, which the leaderboard must add, not count once.
enum TeamQuotaAccount {
    /// Plans are per organization, so the same account in two orgs is two accounts.
    static func claude(_ identity: ClaudeAccountIdentity?) -> String? {
        guard let identity else { return nil }
        let org = identity.organizationUUID?.lowercased() ?? ""
        return TeamAccountKey.make(provider: "claude", accountID: "quota|\(identity.accountUUID.lowercased())|\(org)")
    }

    /// The ChatGPT user and the account (workspace) the login uses: a Team workspace's account id is
    /// the same for all its members, and one person can have a personal and a workspace account.
    static func codex(_ tokens: CodexTokens?) -> String? {
        guard let idToken = tokens?.idToken, let payload = ProviderParse.jwtPayload(idToken) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let user = (auth?["chatgpt_user_id"] as? String)?.nilIfEmpty
            ?? (auth?["user_id"] as? String)?.nilIfEmpty
            ?? (payload["sub"] as? String)?.nilIfEmpty
        guard let user else { return nil }
        let account = tokens?.accountID?.nilIfEmpty ?? (auth?["chatgpt_account_id"] as? String)?.nilIfEmpty ?? ""
        return TeamAccountKey.make(provider: "codex", accountID: "quota|\(user)|\(account)")
    }
}
