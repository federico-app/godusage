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

    /// Providers whose limit windows keep their reset time when a reset is claimed. Codex starts a new
    /// week instead, which `record` already ends the old week for, so it never infers a claim.
    static let claimProviders: Set<String> = ["claude"]
    /// A drop counts as a claimed reset only when the share falls by at least this many points and this
    /// share of what it was, so rounding (a point) and small re-pricing never count.
    static let claimMinimumDrop = 5.0
    static let claimMinimumDropShare = 0.25
    /// Two claims this close are one: a claim GodUsage made and the drop after it, read moments later
    /// (or by a Mac whose clock is off by minutes).
    static let sameClaimSlack: TimeInterval = 30 * 60
    /// The fastest anyone plausibly uses a weekly limit, in points per hour. A share after a drop that
    /// grew faster than this since the reading before can't be fresh use after a reset (a plan upgrade or
    /// a raised limit rescales the share at once), and a share back near its old peak faster than this
    /// means the drop was a glitch.
    static let plausibleRate = 20.0
    /// An inferred claim whose share comes back near its old peak within this long (or faster than
    /// `plausibleRate`) was a glitch, like a share read as 0 once before the Mac slept.
    static let glitchWindow: TimeInterval = 12 * 3_600
    /// At most this many claims per window are kept and sent (the latest); the server keeps as many.
    static let maxClaims = 20

    static func isClaimDrop(from peak: Double, to percent: Double) -> Bool {
        let drop = peak - percent
        return drop >= claimMinimumDrop && drop >= peak * claimMinimumDropShare
    }

    /// Whether `percent`, read `elapsed` after the last reading, can be fresh use after a reset.
    static func isFreshAfterReset(_ percent: Double, elapsed: TimeInterval) -> Bool {
        percent <= claimMinimumDrop + plausibleRate * max(0, elapsed) / 3_600
    }
}

extension TeamQuotaLog.Window {
    /// Limit windows of Claude and Codex track claimed resets; sessions and other providers don't.
    var tracksClaims: Bool { kind == .limit && TeamQuotaLog.claimProviders.contains(provider) }

    /// The share used in the whole window: the share before each claim plus the share since the last.
    var used: Double { claims.reduce(percent) { $0 + $1.percent } }

    /// The window's start, for telling whether a claim falls in it.
    var startsAt: Date { endsAt.addingTimeInterval(-Double(periodHours) * 3_600) }

    /// When the stretch since the last claim began: the claim itself, else this Mac's first reading.
    var stretchSince: Date? { claims.last?.at ?? firstObservedAt }

    /// Folds in a reading of this window. A reading from before the last claim is ignored: that stretch
    /// is closed. So is a reading right after a claim GodUsage made that still shows the share from
    /// before it (a refresh that started before the claim and landed after). A sharp drop is a reset
    /// claimed elsewhere (claude.ai, another app), unless the share after it grew faster than anyone
    /// uses a week, the plan changed, or a later reading shows it was a glitch. Claims GodUsage made
    /// (`recorded`) are counted at their time.
    mutating func fold(_ reading: TeamQuotaReading, day: String, recorded: [RecordedResetClaim], dayKey: (Date) -> String) {
        defer { if reading.plan != nil { plan = reading.plan } }
        if tracksClaims { applyRecorded(recorded, until: reading.observedAt, dayKey: dayKey) }
        if let last = claims.last, reading.observedAt < last.at { return }
        if tracksClaims, let last = claims.last, last.recorded,
           reading.observedAt.timeIntervalSince(last.at) <= TeamQuotaLog.sameClaimSlack,
           reading.percent >= last.percent - TeamQuotaLog.claimMinimumDrop, last.percent > TeamQuotaLog.claimMinimumDrop {
            AppLog.info(.teams, "a \(provider) reading right after a claimed reset still shows the share before it; ignored")
            return
        }
        if tracksClaims, let last = claims.last, !last.recorded {
            let elapsed = reading.observedAt.timeIntervalSince(last.at)
            let regain = max(0, last.percent - TeamQuotaLog.claimMinimumDrop)
            let window = max(TeamQuotaLog.glitchWindow, regain / TeamQuotaLog.plausibleRate * 3_600)
            if elapsed <= window, reading.percent >= last.percent - TeamQuotaLog.claimMinimumDrop {
                claims.removeLast()
                percent = max(last.percent, percent)
                AppLog.info(.teams, "a drop in \(provider)'s weekly share came back too fast to be use; not a claimed reset")
            }
        }
        let planChanged = plan != nil && reading.plan != nil && plan != reading.plan
        if tracksClaims, reading.observedAt > observedAt, !planChanged, TeamQuotaLog.isClaimDrop(from: percent, to: reading.percent),
           TeamQuotaLog.isFreshAfterReset(reading.percent, elapsed: reading.observedAt.timeIntervalSince(observedAt)) {
            if let last = claims.last, last.recorded, reading.observedAt.timeIntervalSince(last.at) <= TeamQuotaLog.sameClaimSlack {
                // The drop after a claim GodUsage made, read once a stale share slipped in: the same claim.
                claims[claims.count - 1].percent = max(last.percent, percent)
            } else {
                claims.append(TeamQuotaLog.Claim(at: reading.observedAt, after: observedAt, percent: percent, day: day, recorded: false))
                trimClaims()
            }
            percent = reading.percent
        } else {
            percent = max(percent, reading.percent)
        }
        observedAt = max(observedAt, reading.observedAt)
        recordDay(day, percent: used)
    }

    /// Keeps the latest `maxClaims` claims, folding older ones' shares into the oldest kept one so the
    /// total use stays right.
    mutating func trimClaims() {
        guard claims.count > TeamQuotaLog.maxClaims else { return }
        let dropped = claims.prefix(claims.count - TeamQuotaLog.maxClaims)
        claims.removeFirst(dropped.count)
        claims[0].percent += dropped.reduce(0) { $0 + $1.percent }
    }

    /// Takes in the same window named another way (this card's copy named per Mac): the claims first,
    /// each once, then each copy's share since its last claim into the stretch it was read in, so a
    /// share from before a claim raises that claim's share instead of the share after it.
    mutating func merge(_ other: TeamQuotaLog.Window) {
        let mine = (percent: percent, observedAt: observedAt)
        mergeClaims(other.claims)
        percent = 0
        for copy in [mine, (percent: other.percent, observedAt: other.observedAt)] {
            if let index = claims.firstIndex(where: { $0.at > copy.observedAt }) {
                claims[index].percent = max(claims[index].percent, copy.percent)
            } else {
                percent = max(percent, copy.percent)
            }
        }
        observedAt = max(observedAt, other.observedAt)
        firstObservedAt = [firstObservedAt, other.firstObservedAt].compactMap { $0 }.min()
        for day in other.days { recordDay(day.day, percent: day.percent) }
        trimClaims()
    }

    /// Counts GodUsage's own claims of this window's general weekly limit made by `until`. A claim the
    /// log already inferred from the drop becomes that claim (never a second one). A model-only reset
    /// (Fable's weekly limit) leaves this window alone.
    mutating func applyRecorded(_ recorded: [RecordedResetClaim], until: Date, dayKey: (Date) -> String) {
        for claim in recorded where claim.windows.contains(.weekly) && claim.at > startsAt && claim.at <= endsAt && claim.at <= until
            && claim.at >= (firstObservedAt ?? .distantPast) {
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
            trimClaims()
        }
    }

    /// Takes in the claims of the same window named another way, each claim once, keeping the higher
    /// share before it (a recorded claim with an unknown share never hides a real one).
    mutating func mergeClaims(_ other: [TeamQuotaLog.Claim]) {
        for claim in other {
            if let index = claims.firstIndex(where: {
                $0.after.addingTimeInterval(-TeamQuotaLog.sameClaimSlack) <= claim.at && claim.after <= $0.at.addingTimeInterval(TeamQuotaLog.sameClaimSlack)
            }) {
                claims[index].percent = max(claims[index].percent, claim.percent)
                if claim.recorded && !claims[index].recorded {
                    claims[index].recorded = true
                    claims[index].at = claim.at
                    claims[index].after = claim.after
                    claims[index].day = claim.day
                }
            } else {
                claims.append(claim)
            }
        }
        claims.sort { $0.at < $1.at }
    }

    /// The claims as the upload sends them: nil for windows that don't track claims, so the server
    /// tells them from an app before claims (which sends none at all).
    var wireClaims: [TeamUsageUpload.QuotaClaim]? {
        guard tracksClaims else { return nil }
        return claims.suffix(TeamQuotaLog.maxClaims).map {
            TeamUsageUpload.QuotaClaim(
                at: TeamUsageUpload.instant($0.at), after: TeamUsageUpload.instant($0.after),
                percent: TeamQuotaLog.tenth($0.percent), day: $0.day, recorded: $0.recorded
            )
        }
    }
}
