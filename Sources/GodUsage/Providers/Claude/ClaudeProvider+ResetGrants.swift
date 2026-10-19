import Foundation

/// The last reset-grants answer for one login. A failed attempt keeps the previous line and still counts
/// as the hour's check, so an outage or 429 is retried an hour later rather than on every refresh.
struct ClaudeResetGrantsCheck {
    var credentialFingerprint: Data
    var checkedAt: Date
    var line: MetricLine?
}

extension ClaudeProvider {
    static let resetGrantsCheckInterval: TimeInterval = 60 * 60

    /// The Rate Limit Resets row, asking Anthropic at most once an hour per login. Claude Code itself only
    /// asks occasionally, and sending the reset-grants variant on every refresh came with sustained 429s
    /// on the usage endpoint. Runs only after a successful usage fetch, so the token is known-good and a
    /// failure here costs the row, never the bars, the warning, or the usage cooldown.
    func resetGrantsLine(credentials: ClaudeOAuth, usageURL: URL) async -> MetricLine? {
        let fingerprint = Self.credentialFingerprint(credentials)
        let now = now()
        let previous = resetGrantsCheck?.credentialFingerprint == fingerprint ? resetGrantsCheck : nil
        let held = previous?.line.map { ClaudeUsageMapper.droppingElapsedResetGrants($0, now: now) }
        if let previous, now.timeIntervalSince(previous.checkedAt) < Self.resetGrantsCheckInterval {
            return held
        }
        do {
            let response = try await usageClient.fetchResetGrants(
                accessToken: credentials.accessToken ?? "", usageURL: usageURL
            )
            let line = try ClaudeUsageMapper.mapResetGrantsResponse(response, now: now)
            resetGrantsCheck = ClaudeResetGrantsCheck(credentialFingerprint: fingerprint, checkedAt: now, line: line)
            return line
        } catch {
            // A cancelled refresh is not a verdict on the endpoint; let the next refresh try again.
            guard !Task.isCancelled else { return held }
            AppLog.warn(LogTag.plugin("claude"), "reset grants lookup failed; retrying in an hour: \(error.localizedDescription)")
            resetGrantsCheck = ClaudeResetGrantsCheck(credentialFingerprint: fingerprint, checkedAt: now, line: previous?.line)
            return held
        }
    }

    /// A guarded token renewal keeps the same login, so the hourly check carries over to the rotated pair
    /// instead of costing an extra reset-grants request.
    func carryResetGrantsCheck(from previous: ClaudeOAuth, to renewed: ClaudeOAuth) {
        guard resetGrantsCheck?.credentialFingerprint == Self.credentialFingerprint(previous) else { return }
        resetGrantsCheck?.credentialFingerprint = Self.credentialFingerprint(renewed)
    }
}
