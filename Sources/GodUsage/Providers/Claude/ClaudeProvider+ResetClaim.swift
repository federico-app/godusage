import Foundation

extension ClaudeProvider {
    /// Spends the next reset grant (`next_grant_id` from the hourly reset-grants check). Lives on the
    /// provider so credential selection can't drift from `refresh()`. Only the resets popover's
    /// confirmed claim calls it; it never retries on its own. Never throws: every failure is logged and
    /// collapsed to an outcome. See docs/research/claude-reset-grant-claim.md.
    func claimResetGrant(redeemRequestID: String) async -> ResetClaimOutcome {
        let tag = LogTag.plugin("claude")
        guard !resetClaimInFlight else {
            AppLog.error(tag, "reset claim: another claim is still running for \(provider.id)")
            return .failed
        }
        // Read the grant and the login that saw it together, before any await: a refresh for another
        // login could replace the check mid-claim and pair this grant with that login.
        guard let check = resetGrantsCheck, let grantID = check.status?.claimableGrantID else {
            AppLog.warn(tag, "reset claim: no claimable grant in the last reset-grants check")
            return .noCredit
        }
        // A claim whose answer never settled may have landed. Retrying it under its original request id
        // lets Anthropic answer `already_used` instead of spending another reset.
        let requestID = unsettledResetClaim?.grantID == grantID
            ? unsettledResetClaim?.requestID ?? redeemRequestID
            : redeemRequestID
        guard Self.matches(grantID, Self.grantIDPattern), Self.matches(requestID, Self.requestIDPattern) else {
            AppLog.error(tag, "reset claim: refusing a malformed grant id or request id")
            return .failed
        }
        resetClaimInFlight = true
        defer { resetClaimInFlight = false }

        // Only the login the grants were read with may claim. Grant ids are shared promos, so another
        // login on this Mac could hold the same id and would spend its own reset instead.
        guard let state = await resetClaimLogin(fingerprint: check.credentialFingerprint) else {
            AppLog.error(tag, "reset claim: the login the grants were read with is no longer available; nothing sent")
            return .failed
        }
        let usageURL: URL
        do {
            usageURL = try authStore.usageEndpoint()
        } catch {
            AppLog.error(tag, "reset claim: \(error.localizedDescription)")
            return .failed
        }
        let accessToken = state.oauth.accessToken ?? ""
        guard let organizationUUID = await claimOrganization(for: state, accessToken: accessToken) else {
            return .failed
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.claimResetGrant(
                accessToken: accessToken, organizationUUID: organizationUUID,
                grantID: grantID, requestID: requestID, usageURL: usageURL
            )
        } catch {
            AppLog.error(tag, "reset claim: request failed: \(error.localizedDescription)")
            unsettledResetClaim = (grantID, requestID)
            return .failed
        }
        let outcome = Self.resetClaimOutcome(from: response)
        recordSettlement(response: response, outcome: outcome, grantID: grantID, requestID: requestID)
        let preview = LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 500)
        if outcome == .success {
            AppLog.info(tag, "reset claim: \(response.statusCode) \(preview)")
        } else {
            AppLog.error(tag, "reset claim: \(outcome) (\(response.statusCode)): \(preview)")
        }
        switch outcome {
        case .success, .unconfirmed:
            forgetGrantsAfterResetClaim()
            forgetLiveUsageAfterResetClaim()
        case .noCredit:
            forgetGrantsAfterResetClaim()
        case .nothingToReset, .unavailableNow, .failed:
            break
        }
        return outcome
    }

    /// Only a definitive answer settles the request id. A server error, an unreadable body, or
    /// `unconfirmed` leaves it unknown whether the reset was spent, so the id is kept for the next
    /// retry. A 4xx refused this attempt without saying whether an earlier one under the same id
    /// landed, so it leaves any earlier unsettled claim in place.
    private func recordSettlement(
        response: HTTPResponse, outcome: ResetClaimOutcome, grantID: String, requestID: String
    ) {
        let success = (200..<300).contains(response.statusCode)
        let readable = success && ProviderParse.jsonObject(response.body)?["result"] != nil
        if readable && outcome != .unconfirmed {
            unsettledResetClaim = nil
        } else if response.statusCode >= 500 || success {
            unsettledResetClaim = (grantID, requestID)
        }
    }

    /// The login with this fingerprint. Falls back to the Desktop-forced load, because `refresh()` reads
    /// grants with the Desktop login when the Claude Code login is rejected. Never prompts: the login
    /// was already read in this process to fetch the grants. An expired token gets the same guarded
    /// renewal `refresh()` uses.
    private func resetClaimLogin(fingerprint: Data) async -> ClaudeCredentialState? {
        for forceDesktop in [false, true] {
            let load = await loadOffMainActor { [authStore] in
                authStore.loadCredentialSet(forceDesktopFallback: forceDesktop)
            }
            guard var state = load.candidates.first(where: {
                $0.hasUsableAccessToken && Self.credentialFingerprint($0.oauth) == fingerprint
            }) else { continue }
            guard authStore.isExpired(state.oauth) else { return state }
            guard let renewed = await renewToken(for: state) else {
                AppLog.warn(LogTag.plugin("claude"), "reset claim: \(state.source.label) token expired and renewal declined")
                return nil
            }
            carryResetGrantsCheck(from: state.oauth, to: renewed)
            state.oauth = renewed
            return state
        }
        return nil
    }

    /// The organization to claim against, from the profile already learned for this token or a fresh
    /// profile read. Refuses a token whose account isn't the card's. `nil` (logged) when it can't be
    /// established.
    private func claimOrganization(for state: ClaudeCredentialState, accessToken: String) async -> String? {
        let tag = LogTag.plugin("claude")
        let account: ClaudeAccountIdentity
        if let known = accountVerifier.knownAccount(fingerprint: Self.credentialFingerprint(state.oauth)) {
            account = known
        } else {
            do {
                let response = try await usageClient.fetchProfile(
                    accessToken: accessToken, profileURL: try authStore.profileEndpoint()
                )
                guard (200..<300).contains(response.statusCode),
                      let parsed = ClaudeAccountIdentity.fromProfileResponse(response.body)
                else {
                    AppLog.error(tag, "reset claim: profile lookup failed (HTTP \(response.statusCode))")
                    return nil
                }
                account = parsed
            } catch {
                AppLog.error(tag, "reset claim: profile lookup failed: \(error.localizedDescription)")
                return nil
            }
        }
        if let expected = state.expectedAccount, !account.isSameAccount(as: expected) {
            AppLog.error(tag, "reset claim: the login belongs to another account than the card; nothing sent")
            return nil
        }
        guard let uuid = account.organizationUUID, UUID(uuidString: uuid) != nil else {
            AppLog.error(tag, "reset claim: the profile names no valid organization")
            return nil
        }
        return uuid
    }

    /// A claim changed which grants exist, so re-read them on the next refresh. Bumping the epoch stops
    /// a grants or usage read that started before the claim from caching its pre-claim answer.
    func forgetGrantsAfterResetClaim() {
        resetGrantsCheck = nil
        resetClaimEpoch += 1
    }

    /// Collapses a claim response to the popover's outcome. The popover's request id is fresh per
    /// node, so `already_used` can only answer our own earlier attempt and counts as claimed.
    static func resetClaimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let result = body["result"] as? String
        else { return .failed }
        let cooldownUntil = ClaudeUsageMapper.resetDate(body["cooldown_until"])
        func outcome(_ code: String) -> ResetClaimOutcome? {
            switch code {
            case "reset", "already_used": .success
            case "not_limited": .nothingToReset
            case "ineligible", "no_grant", "unknown_grant", "not_next_grant": .noCredit
            case "reset_unconfirmed", "stamp_indeterminate": .unconfirmed
            case "cooldown", "paused", "low_priority_active": .unavailableNow(until: cooldownUntil)
            default: nil
            }
        }
        if result == "unavailable" {
            return (body["reason"] as? String).flatMap(outcome) ?? .failed
        }
        return outcome(result) ?? .failed
    }

    private static let grantIDPattern = "^[a-z0-9_-]{1,40}$"
    private static let requestIDPattern = "^[A-Za-z0-9_-]{1,64}$"

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The resets popover's claim seam for one Claude card: the provider's claim plus a forced refresh, so
/// the result banner appears over already-reconciled meters.
@MainActor
final class ClaudeResetClaimService: ResetClaimService {
    private let provider: ClaudeProvider
    private let refreshAfterClaim: () async -> Void

    init(provider: ClaudeProvider, refreshAfterClaim: @escaping () async -> Void = {}) {
        self.provider = provider
        self.refreshAfterClaim = refreshAfterClaim
    }

    var isClaimable: Bool { provider.resetGrantsCheck?.status?.claimableGrantID != nil }
    var confirmDetail: String? { provider.resetGrantsCheck?.status?.confirmDetail }

    /// Claude always spends `next_grant_id`, so the picked node's expiry is ignored.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let outcome = await provider.claimResetGrant(redeemRequestID: redeemRequestID)
        if outcome != .failed { await refreshAfterClaim() }
        return outcome
    }
}
