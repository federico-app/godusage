import Foundation

/// Claimed limit resets in a window that keeps its reset time. Claude doesn't move a weekly window's
/// reset when a reset is claimed: the share used drops to 0 and the same week gets another full limit.
/// (Codex starts a new week instead, which `TeamQuotaLog.record` already ends the old week for.) The log
/// keeps each claim with the share used before it, so the week counts 95 + 40 = 135 of 200 rather than
/// the highest share seen. See the backend's quotaClaims.ts, which merges every Mac's claims.
extension TeamQuotaLog {
    struct Claim: Codable, Hashable, Sendable {
        /// When the reset was claimed: GodUsage's own claim, or the first reading after the drop.
        var at: Date
        /// The last reading before it (the claim itself for one GodUsage made).
        var after: Date
        /// The highest share seen used before it.
        var percent: Double
        /// The local day of `at`.
        var day: String
        /// GodUsage made the claim; otherwise it was inferred from the drop.
        var recorded: Bool
    }

    /// Providers whose limit windows can have a reset claimed.
    static let claimProviders: Set<String> = ["claude", "codex"]
    /// A drop counts as a claimed reset only when the share falls by at least this many points and this
    /// share of what it was, so rounding (a point) and small re-pricing never count.
    static let claimMinimumDrop = 5.0
    static let claimMinimumDropShare = 0.25
    /// Two claims this close are one: a claim GodUsage made and the drop after it, read moments later.
    static let sameClaimSlack: TimeInterval = 15 * 60
    /// An inferred claim whose next reading, this soon, is back near the share before it was a glitch
    /// (a share read as 0 once), not a reset: no one uses that much of a week this fast.
    static let glitchWindow: TimeInterval = 3_600

    static func isClaimDrop(from peak: Double, to percent: Double) -> Bool {
        let drop = peak - percent
        return drop >= claimMinimumDrop && drop >= peak * claimMinimumDropShare
    }
}

extension TeamQuotaLog.Window {
    /// Limit windows of Claude and Codex track claimed resets; sessions and other providers don't.
    var tracksClaims: Bool { kind == .limit && TeamQuotaLog.claimProviders.contains(provider) }

    /// The share used in the whole window: the share before each claim plus the share since the last.
    var used: Double { claims.reduce(percent) { $0 + $1.percent } }

    /// The window's start, for telling whether a claim falls in it.
    var startsAt: Date { endsAt.addingTimeInterval(-Double(periodHours) * 3_600) }

    /// Folds in a reading of this window. A reading from before the last claim is ignored: that stretch
    /// is closed. A sharp drop is a reset claimed elsewhere (claude.ai, another app), unless the next
    /// reading shows it was a glitch. Claims GodUsage made (`recorded`) are counted at their time.
    mutating func fold(_ reading: TeamQuotaReading, day: String, recorded: [RecordedResetClaim], dayKey: (Date) -> String) {
        if tracksClaims { applyRecorded(recorded, until: reading.observedAt, dayKey: dayKey) }
        if let last = claims.last, reading.observedAt < last.at { return }
        if tracksClaims, let last = claims.last, !last.recorded,
           reading.observedAt.timeIntervalSince(last.at) <= TeamQuotaLog.glitchWindow,
           reading.percent >= last.percent - TeamQuotaLog.claimMinimumDrop {
            claims.removeLast()
            percent = max(last.percent, percent)
            AppLog.info(.teams, "a drop in \(provider)'s weekly share came straight back; not a claimed reset")
        }
        if tracksClaims, reading.observedAt > observedAt, TeamQuotaLog.isClaimDrop(from: percent, to: reading.percent) {
            claims.append(TeamQuotaLog.Claim(at: reading.observedAt, after: observedAt, percent: percent, day: day, recorded: false))
            percent = reading.percent
        } else {
            percent = max(percent, reading.percent)
        }
        observedAt = max(observedAt, reading.observedAt)
        recordDay(day, percent: used)
    }

    /// Counts GodUsage's own claims of this window's general weekly limit made by `until`. A claim the
    /// log already inferred from the drop becomes that claim (never a second one). A model-only reset
    /// (Fable's weekly limit) leaves this window alone.
    mutating func applyRecorded(_ recorded: [RecordedResetClaim], until: Date, dayKey: (Date) -> String) {
        for claim in recorded where claim.windows.contains(.weekly) && claim.at > startsAt && claim.at <= endsAt && claim.at <= until {
            if let index = claims.firstIndex(where: {
                $0.after.addingTimeInterval(-TeamQuotaLog.sameClaimSlack) <= claim.at && claim.at <= $0.at.addingTimeInterval(TeamQuotaLog.sameClaimSlack)
            }) {
                guard !claims[index].recorded else { continue }
                claims[index].recorded = true
                if claim.at >= claims[index].after && claim.at <= claims[index].at {
                    claims[index].at = claim.at
                    claims[index].after = claim.at
                    claims[index].day = dayKey(claim.at)
                }
                continue
            }
            let new = TeamQuotaLog.Claim(at: claim.at, after: claim.at, percent: percent, day: dayKey(claim.at), recorded: true)
            if let later = claims.firstIndex(where: { $0.at > claim.at }) {
                // Before a claim already counted: the share before it is unknown here (another Mac may know).
                claims.insert(TeamQuotaLog.Claim(at: claim.at, after: claim.at, percent: 0, day: new.day, recorded: true), at: later)
            } else {
                // The share seen so far was before the claim, unless this Mac read the window after it
                // without seeing a drop: then the claim came with little used, and this overstates it slightly.
                claims.append(new)
                percent = 0
            }
        }
    }

    /// Takes in the claims of the same window named another way, each claim once.
    mutating func mergeClaims(_ other: [TeamQuotaLog.Claim]) {
        for claim in other where !claims.contains(where: {
            $0.after.addingTimeInterval(-TeamQuotaLog.sameClaimSlack) <= claim.at && claim.after <= $0.at.addingTimeInterval(TeamQuotaLog.sameClaimSlack)
        }) {
            claims.append(claim)
        }
        claims.sort { $0.at < $1.at }
    }

    /// The claims as the upload sends them: nil for windows that don't track claims, so the server
    /// tells them from an app before claims (which sends none at all).
    var wireClaims: [TeamUsageUpload.QuotaClaim]? {
        guard tracksClaims else { return nil }
        return claims.map {
            TeamUsageUpload.QuotaClaim(
                at: TeamUsageUpload.instant($0.at), after: TeamUsageUpload.instant($0.after),
                percent: TeamQuotaLog.tenth($0.percent), day: $0.day, recorded: $0.recorded
            )
        }
    }
}
