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
    /// The team whose plan the advice is about, for Open Plans.
    var teamID: String? = nil
    /// The account card a "Switch to …" suggestion recommends, for the menu bar's green dot.
    var targetProviderID: String? = nil
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
        /// The share of the plan's quota on pace to be used, when the report has one.
        var quotaPercent: Double? = nil
        let underused: Bool
        /// Days until the plan renews, counting today (the Plans tab's "N days left").
        let daysLeft: Int
        let cycleEnd: String
        /// The team that set up the plan.
        var teamID: String? = nil
    }

    /// A team plan that covers you and that Live Pace says to "use this now" (another provider's plan
    /// runs hot while this one has room today). It names the alternative in the switch suggestion.
    struct RoomyPlan {
        let family: String
        let name: String
        /// How far today's use is ahead of pace, in working time (negative when under). Nil without a budget.
        let ahead: TimeInterval?
        /// Points of today's budget left.
        let leftToday: Double
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
        quotas: [Quota], resets: [ResetCredits], plans: [Plan], roomyPlans: [RoomyPlan] = [], now: Date
    ) -> [UsageSuggestion] {
        var result: [UsageSuggestion] = []
        result += resets.flatMap { credits(for: $0, now: now) }
        result += quotas.compactMap { useBeforeReset($0, now: now) }
        result += quotas.compactMap {
            switchProvider(from: $0, quotas: quotas, resets: resets, roomyPlans: roomyPlans, now: now)
        }
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
        let name = credits.providerName
        let count = credits.count
        let resetsWord = String(localized: "\(count) resets", comment: "Usage suggestion: how many reset credits you have, e.g. 2 resets")
        if credits.quotaSpent {
            return [UsageSuggestion(
                id: "claim:\(credits.providerID):\(credits.count)",
                kind: .claimReset, family: credits.family,
                title: String(localized: "Claim a \(name) Reset", comment: "Usage suggestion title; the argument is a provider or account name"),
                message: String(
                    localized: "Your \(name) limit is used up, but you have \(resetsWord). Claim one to start fresh.",
                    comment: "Usage suggestion: provider name, then a count of resets such as 2 resets"
                ),
                deadline: upcoming.first
            )]
        }
        if let soonest = upcoming.first, soonest.timeIntervalSince(now) <= expiryHorizon {
            let left = duration(soonest, now)
            let message = credits.count == 1
                ? String(
                    localized: "Your reset expires in \(left). Use \(name) freely: if you hit the limit, claim it before it's gone.",
                    comment: "Usage suggestion: a duration such as 5h 10m, then a provider name"
                )
                : String(
                    localized: "You have \(resetsWord) and one expires in \(left). Use \(name) freely: if you hit the limit, claim it before it's gone.",
                    comment: "Usage suggestion: a count of resets such as 2 resets, a duration such as 5h 10m, then a provider name"
                )
            return [UsageSuggestion(
                id: "expiring:\(credits.providerID):\(Int(soonest.timeIntervalSince1970))",
                kind: .resetExpiring, family: credits.family,
                title: String(localized: "Use \(name), a Reset Expires Soon", comment: "Usage suggestion title; the argument is a provider or account name"),
                message: message,
                deadline: soonest
            )]
        }
        if credits.count >= manyResets {
            return [UsageSuggestion(
                id: "resets:\(credits.providerID):\(credits.count)",
                kind: .resetsAvailable, family: credits.family,
                title: String(localized: "Lean on \(name)", comment: "Usage suggestion title: prefer this provider for now"),
                message: String(
                    localized: "You have \(resetsWord), so \(name)'s limits stretch further. Prefer it for heavy work.",
                    comment: "Usage suggestion: a count of resets such as 2 resets, then a provider name"
                ),
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
        let name = quota.providerName
        let metric = LocalizedMetricTitle.string(quota.metricTitle)
        let untilResetText = duration(resetsAt, now)
        return UsageSuggestion(
            id: "use:\(quota.providerID):\(quota.metricTitle):\(Int(resetsAt.timeIntervalSince1970 / 3600))",
            kind: .useBeforeReset, family: quota.family,
            title: String(localized: "Use \(name) Before It Resets", comment: "Usage suggestion title; the argument is a provider or account name"),
            message: String(
                localized: "About \(percentLeft)% of your \(metric) will go unused: it resets in \(untilResetText). Use \(name) first.",
                comment: "Usage suggestion: a percentage, a limit name such as Weekly, a duration such as 1d 4h, then a provider name"
            ),
            deadline: resetsAt
        )
    }

    /// A window running out before its reset, with a roomier provider to move to. Without an
    /// alternative the red bar already says everything.
    private static func switchProvider(
        from quota: Quota, quotas: [Quota], resets: [ResetCredits], roomyPlans: [RoomyPlan], now: Date
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
        let spent: Bool = if case .spent = state { true } else { false }
        return UsageSuggestion(
            id: "switch:\(quota.providerID):\(target.providerID):\(Int((quota.data.resetsAt ?? now).timeIntervalSince1970 / 3600))",
            kind: .switchProvider, family: target.family,
            title: String(localized: "Switch to \(target.providerName)", comment: "Usage suggestion title; the argument is a provider or account name"),
            message: switchMessage(
                from: quota, spent: spent, to: target, left: left,
                plan: roomyPlans.first { $0.family == target.family }
            ),
            deadline: quota.data.resetsAt,
            targetProviderID: target.providerID
        )
    }

    /// The switch suggestion's text. With a team plan for the alternative that Live Pace says to use
    /// now, it names that plan and how far under pace it is: "Claude (Appload) will hit its Weekly
    /// limit before the reset. ChatGPT Plus is 2h 48m under pace." Otherwise it says what the
    /// alternative's own window has left.
    static func switchMessage(from quota: Quota, spent: Bool, to target: Quota, left: Double, plan: RoomyPlan?) -> String {
        let name = quota.providerName
        let metric = LocalizedMetricTitle.string(quota.metricTitle)
        guard let plan else {
            let targetName = target.providerName
            let targetMetric = LocalizedMetricTitle.string(target.metricTitle)
            let percent = Int((left * 100).rounded())
            return spent
                ? String(
                    localized: "Your \(name) \(metric) is used up. \(targetName) has \(percent)% of its \(targetMetric) left.",
                    comment: "Usage suggestion: provider, its used-up limit such as Weekly, then another provider, the percentage it has left and its limit name"
                )
                : String(
                    localized: "\(name) is on pace to hit its \(metric) limit before it resets. \(targetName) has \(percent)% of its \(targetMetric) left.",
                    comment: "Usage suggestion: provider, its limit such as Weekly, then another provider, the percentage it has left and its limit name"
                )
        }
        let planName = plan.name
        if let ahead = plan.ahead, ahead <= -LivePace.onPaceMargin {
            let under = LivePaceFormat.duration(ahead)
            return spent
                ? String(
                    localized: "Your \(name) \(metric) is used up. \(planName) is \(under) under pace.",
                    comment: "Usage suggestion: provider, its used-up limit such as Weekly, then a team plan name and how far under pace it is, e.g. 2h 48m"
                )
                : String(
                    localized: "\(name) will hit its \(metric) limit before the reset. \(planName) is \(under) under pace.",
                    comment: "Usage suggestion: provider, its limit such as Weekly, then a team plan name and how far under pace it is, e.g. 2h 48m"
                )
        }
        let leftToday = LivePaceFormat.percent(plan.leftToday)
        return spent
            ? String(
                localized: "Your \(name) \(metric) is used up. \(planName) has \(leftToday) of today’s budget left.",
                comment: "Usage suggestion: provider, its used-up limit such as Weekly, then a team plan name and the share of today's budget it has left, e.g. 7.5%"
            )
            : String(
                localized: "\(name) will hit its \(metric) limit before the reset. \(planName) has \(leftToday) of today’s budget left.",
                comment: "Usage suggestion: provider, its limit such as Weekly, then a team plan name and the share of today's budget it has left, e.g. 7.5%"
            )
    }

    private static func planUnderused(_ plan: Plan) -> UsageSuggestion? {
        guard plan.underused, plan.daysLeft <= planHorizonDays else { return nil }
        return UsageSuggestion(
            id: "plan:\(plan.id):\(plan.cycleEnd)",
            kind: .planUnderused, family: plan.family,
            title: String(localized: "Use the Team's \(plan.providerName) Plan", comment: "Usage suggestion title; the argument is a provider name"),
            message: planUnderusedMessage(plan),
            deadline: nil,
            teamID: plan.teamID
        )
    }

    /// "ChatGPT Plus is on pace for 40% of its quota and renews in 3 days. …", one full sentence per
    /// variant (quota share or cost multiple, renewing tomorrow or in N days).
    private static func planUnderusedMessage(_ plan: Plan) -> String {
        let name = plan.name
        let provider = plan.providerName
        let days = plan.daysLeft
        if let quota = plan.quotaPercent {
            let percent = Int(quota.rounded())
            return days == 1
                ? String(
                    localized: "\(name) is on pace for \(percent)% of its quota and renews tomorrow. Use \(provider) to get the team's money's worth.",
                    comment: "Usage suggestion: a team plan name, the share of its quota on pace to be used, then a provider name"
                )
                : String(
                    localized: "\(name) is on pace for \(percent)% of its quota and renews in \(days) days. Use \(provider) to get the team's money's worth.",
                    comment: "Usage suggestion: a team plan name, the share of its quota on pace to be used, days until it renews, then a provider name"
                )
        }
        let multiple = AppLocale.decimal(plan.projectedMultiple, digits: 1)
        return days == 1
            ? String(
                localized: "\(name) is on pace for \(multiple)× its cost and renews tomorrow. Use \(provider) to get the team's money's worth.",
                comment: "Usage suggestion: a team plan name, how many times its cost it is on pace to use (e.g. 0.4), then a provider name"
            )
            : String(
                localized: "\(name) is on pace for \(multiple)× its cost and renews in \(days) days. Use \(provider) to get the team's money's worth.",
                comment: "Usage suggestion: a team plan name, how many times its cost it is on pace to use (e.g. 0.4), days until it renews, then a provider name"
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
        Formatters.compactDuration(date.timeIntervalSince(now)) ?? String(localized: "moments", comment: "Usage suggestion: a duration too short to show, as in 'expires in moments'")
    }
}
