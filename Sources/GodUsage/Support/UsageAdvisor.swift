import Foundation

/// One piece of advice about which provider to use right now. `id` is stable for as long as the
/// situation lasts (the same window, credit, or billing cycle), so a dismissal or a notification
/// sticks to the situation and a new one surfaces again.
struct UsageSuggestion: Equatable, Identifiable, Sendable {
    enum Kind: Int, Comparable, Sendable {
        // Declaration order is priority order, most urgent first.
        case claimReset, resetExpiring, useBeforeReset, switchProvider, planUnderused, resetsAvailable

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let kind: Kind
    /// The provider family the advice is about (`claude`, `codex`), for its color and icon.
    let family: String
    let title: String
    let message: String
    /// When the opportunity ends; ties within a kind go to the soonest.
    let deadline: Date?
}

/// Turns this Mac's quotas, its reset credits, and the team's plans into suggestions, most urgent
/// first. Pure: every input is a value, and `now` is passed in.
enum UsageAdvisor {
    /// A bounded quota window (Weekly, Cursor's monthly Total Usage) on one provider card.
    struct Quota {
        let providerID: String
        let family: String
        let providerName: String
        let metricTitle: String
        let data: WidgetData
    }

    /// A card's reset credits: what's left and when each one expires. `quotaSpent` is whether the
    /// card's main window is used up, the moment a credit is worth claiming.
    struct ResetCredits {
        let providerID: String
        let family: String
        let providerName: String
        let count: Int
        let expiries: [Date]
        let quotaSpent: Bool
    }

    /// A team plan from the Plans report, with whether this Mac uses its provider.
    struct Plan {
        let id: String
        let family: String
        let providerName: String
        let name: String
        let projectedMultiple: Double
        let underused: Bool
        /// Days until the plan renews, counting today (the Plans tab's "N days left").
        let daysLeft: Int
        let cycleEnd: String
    }

    /// A window is worth spending when at least this share is still projected to be left at reset…
    static let minimumLeftAtReset = 0.3
    /// …and the reset is within this share of the window (about 2 days of a week, 9 of a month).
    static let resetHorizonShare = 0.3
    /// Too close to the reset to act on.
    static let minimumTimeToReset: TimeInterval = 30 * 60
    static let expiryHorizon: TimeInterval = 48 * 3600
    static let planHorizonDays = 7
    /// Below this many credits, an unexpiring stock is not worth a banner.
    static let manyResets = 2

    static func suggestions(
        quotas: [Quota], resets: [ResetCredits], plans: [Plan], now: Date
    ) -> [UsageSuggestion] {
        var result: [UsageSuggestion] = []
        result += resets.flatMap { credits(for: $0, now: now) }
        result += quotas.compactMap { useBeforeReset($0, now: now) }
        result += quotas.compactMap { switchProvider(from: $0, quotas: quotas, resets: resets, now: now) }
        result += plans.compactMap(planUnderused)
        return result.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return (lhs.deadline ?? .distantFuture) < (rhs.deadline ?? .distantFuture)
        }
    }

    // MARK: - Rules

    private static func credits(for credits: ResetCredits, now: Date) -> [UsageSuggestion] {
        guard credits.count > 0 else { return [] }
        let upcoming = credits.expiries.filter { $0 > now }.sorted()
        let resetsWord = credits.count == 1 ? "1 reset" : "\(credits.count) resets"
        if credits.quotaSpent {
            return [UsageSuggestion(
                id: "claim:\(credits.providerID):\(credits.count)",
                kind: .claimReset, family: credits.family,
                title: "Claim a \(credits.providerName) Reset",
                message: "Your \(credits.providerName) limit is used up, but you have \(resetsWord). Claim one to start fresh.",
                deadline: upcoming.first
            )]
        }
        if let soonest = upcoming.first, soonest.timeIntervalSince(now) <= expiryHorizon {
            let lead = credits.count == 1
                ? "Your reset expires in \(duration(soonest, now))"
                : "You have \(resetsWord) and one expires in \(duration(soonest, now))"
            return [UsageSuggestion(
                id: "expiring:\(credits.providerID):\(Int(soonest.timeIntervalSince1970))",
                kind: .resetExpiring, family: credits.family,
                title: "Use \(credits.providerName), a Reset Expires Soon",
                message: "\(lead). Use \(credits.providerName) freely: if you hit the limit, claim it before it's gone.",
                deadline: soonest
            )]
        }
        if credits.count >= manyResets {
            return [UsageSuggestion(
                id: "resets:\(credits.providerID):\(credits.count)",
                kind: .resetsAvailable, family: credits.family,
                title: "Lean on \(credits.providerName)",
                message: "You have \(resetsWord), so \(credits.providerName)'s limits stretch further. Prefer it for heavy work.",
                deadline: upcoming.first
            )]
        }
        return []
    }

    private static func useBeforeReset(_ quota: Quota, now: Date) -> UsageSuggestion? {
        guard let resetsAt = quota.data.resetsAt, let left = leftAtReset(quota.data, now: now) else { return nil }
        let untilReset = resetsAt.timeIntervalSince(now)
        guard left >= minimumLeftAtReset, untilReset >= minimumTimeToReset,
              let period = period(quota.data), untilReset <= period * resetHorizonShare else { return nil }
        let percentLeft = Int((left * 100).rounded())
        return UsageSuggestion(
            id: "use:\(quota.providerID):\(quota.metricTitle):\(Int(resetsAt.timeIntervalSince1970 / 3600))",
            kind: .useBeforeReset, family: quota.family,
            title: "Use \(quota.providerName) Before It Resets",
            message: "About \(percentLeft)% of your \(quota.metricTitle) will go unused: it resets in \(duration(resetsAt, now)). Use \(quota.providerName) first.",
            deadline: resetsAt
        )
    }

    /// A window running out before its reset, with a roomier provider to move to. Without an
    /// alternative the red bar already says everything.
    private static func switchProvider(
        from quota: Quota, quotas: [Quota], resets: [ResetCredits], now: Date
    ) -> UsageSuggestion? {
        let state = quota.data.meterState(now: now)
        switch state {
        case .runningOut, .spent: break
        default: return nil
        }
        // A spent window with a credit to claim is the claim suggestion's job.
        if case .spent = state, resets.contains(where: { $0.providerID == quota.providerID && $0.count > 0 }) {
            return nil
        }
        let alternative = quotas
            .filter { $0.family != quota.family }
            .compactMap { other in leftNow(other.data, now: now).map { (other, $0) } }
            .filter { $0.1 >= minimumLeftAtReset }
            .max { $0.1 < $1.1 }
        guard let (target, left) = alternative else { return nil }
        var reason = "\(quota.providerName) is on pace to hit its \(quota.metricTitle) limit before it resets."
        if case .spent = state { reason = "Your \(quota.providerName) \(quota.metricTitle) is used up." }
        return UsageSuggestion(
            id: "switch:\(quota.providerID):\(target.providerID):\(Int((quota.data.resetsAt ?? now).timeIntervalSince1970 / 3600))",
            kind: .switchProvider, family: target.family,
            title: "Switch to \(target.providerName)",
            message: "\(reason) \(target.providerName) has \(Int((left * 100).rounded()))% of its \(target.metricTitle) left.",
            deadline: quota.data.resetsAt
        )
    }

    private static func planUnderused(_ plan: Plan) -> UsageSuggestion? {
        guard plan.underused, plan.daysLeft <= planHorizonDays else { return nil }
        let days = plan.daysLeft == 1 ? "tomorrow" : "in \(plan.daysLeft) days"
        let multiple = String(format: "%.1f×", plan.projectedMultiple)
        return UsageSuggestion(
            id: "plan:\(plan.id):\(plan.cycleEnd)",
            kind: .planUnderused, family: plan.family,
            title: "Use the Team's \(plan.providerName) Plan",
            message: "\(plan.name) is on pace for \(multiple) its cost and renews \(days). Use \(plan.providerName) to get the team's money's worth.",
            deadline: nil
        )
    }

    // MARK: - Helpers

    /// Share of the window projected to be left at reset: the pace projection when there is one,
    /// otherwise what's left now (a window too young or too idle to project). Nil for a window that
    /// is tight, running out, or has no data.
    static func leftAtReset(_ data: WidgetData, now: Date) -> Double? {
        switch data.meterState(now: now) {
        case .healthy(let projectedFraction): return max(0, 1 - projectedFraction)
        case .level(.normal): return data.remainingFraction
        default: return nil
        }
    }

    /// Share left now, for a window that isn't itself in trouble.
    private static func leftNow(_ data: WidgetData, now: Date) -> Double? {
        switch data.meterState(now: now) {
        case .healthy, .level(.normal): return data.remainingFraction
        default: return nil
        }
    }

    private static func period(_ data: WidgetData) -> TimeInterval? {
        guard let ms = data.periodDurationMs, ms > 0 else { return nil }
        return TimeInterval(ms) / 1000
    }

    private static func duration(_ date: Date, _ now: Date) -> String {
        Formatters.compactDuration(date.timeIntervalSince(now)) ?? "moments"
    }
}
