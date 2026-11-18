import Foundation

struct TeamsUser: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
}

struct TeamsSession: Codable, Hashable, Sendable {
    var token: String
    var user: TeamsUser
}

struct TeamSummary: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var memberCount: Int
}

struct UsageTotals: Decodable, Hashable, Sendable {
    var tokens: Int
    var costUSD: Double
}

/// `GET /v1/me/usage`: the user's own last 30 days across their Macs.
struct MyUsage: Decodable, Hashable, Sendable {
    struct Day: Decodable, Hashable, Identifiable, Sendable {
        var day: String
        var tokens: Int
        var costUSD: Double
        var id: String { day }
    }

    struct Provider: Decodable, Hashable, Identifiable, Sendable {
        var provider: String
        var tokens: Int
        var costUSD: Double
        var id: String { provider }
    }

    var days: [Day]
    var providers: [Provider]
    var lastSyncAt: String?

    var today: Day? { days.last }
    var total: UsageTotals {
        UsageTotals(tokens: days.reduce(0) { $0 + $1.tokens }, costUSD: days.reduce(0) { $0 + $1.costUSD })
    }
}

enum BoardRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7 Days")
        case .month: String(localized: "30 Days")
        }
    }

    /// A member's movement since the previous period, as a sentence: "Up 2 since yesterday". One
    /// sentence per range, so each language words the period its own way.
    func movement(_ change: Int) -> String {
        let places = abs(change)
        switch self {
        case .today:
            if change == 0 { return String(localized: "Same as yesterday", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since yesterday", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since yesterday", comment: "Member rank movement: places lost")
        case .week:
            if change == 0 { return String(localized: "Same as the previous 7 days", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since the previous 7 days", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since the previous 7 days", comment: "Member rank movement: places lost")
        case .month:
            if change == 0 { return String(localized: "Same as the previous 30 days", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since the previous 30 days", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since the previous 30 days", comment: "Member rank movement: places lost")
        }
    }
}

/// Spend and tokens of one provider (`backend/src/stats.ts`).
struct ProviderTotals: Decodable, Hashable, Identifiable, Sendable {
    var provider: String
    var tokens: Int
    var costUSD: Double
    var id: String { provider }
}

/// The parts of a team's stats (`GET /v1/teams/:id/stats`) the phone shows: totals, the ranked
/// members, and the team's providers, models, and days.
struct TeamBoard: Decodable, Hashable, Sendable {
    struct Previous: Decodable, Hashable, Sendable {
        var rank: Int
        var tokens: Int
        var costUSD: Double
    }

    struct Member: Decodable, Hashable, Identifiable, Sendable {
        var userID: String
        var displayName: String
        var rank: Int
        var tokens: Int
        var costUSD: Double
        var providers: [ProviderTotals]
        /// The member in the period before; nil when they had no usage then.
        var previous: Previous?
        var lastSyncAt: String?
        var id: String { userID }

        /// Places gained (positive) or lost (negative) since the previous period; nil when the member
        /// had no usage then.
        var rankChange: Int? { previous.map { $0.rank - rank } }
    }

    struct Model: Decodable, Hashable, Identifiable, Sendable {
        var model: String
        var provider: String
        var tokens: Int
        var costUSD: Double
        var id: String { "\(provider)/\(model)" }
    }

    struct Day: Decodable, Hashable, Identifiable, Sendable {
        var day: String
        var providers: [ProviderTotals]
        var id: String { day }
    }

    var totals: UsageTotals
    var members: [Member]
    /// Every provider, shared accounts included, largest first.
    var providers: [ProviderTotals]
    /// The period's largest models (up to 20), largest first.
    var models: [Model]
    /// Every day of the period, oldest first, with no gaps.
    var daily: [Day]
}

/// `GET /v1/teams/:id/plans`: the team's plans. The phone reads only each plan's open weekly limit
/// (`budget`, see `backend/src/quotaHistory.ts`); a plan without one has no budget.
struct TeamPlans: Decodable, Hashable, Sendable {
    struct Plan: Decodable, Hashable, Identifiable, Sendable {
        var id: String
        var provider: String
        var name: String
        var budget: Budget?
    }

    struct Budget: Decodable, Hashable, Sendable {
        /// The share of the weekly limit used today.
        var todayPercent: Double
        /// What today can use and keep the week on pace.
        var affordablePercent: Double
        /// The share left at the start of today.
        var leftPercent: Double
        /// When the soonest account's week resets (ISO 8601).
        var resetsAt: String
        var accounts: Int
        /// Each account with an open week; nil from older servers.
        var perAccount: [AccountWeek]?
        /// Set when a limit reset was claimed in an open week.
        var week: WeekCapacity?

        /// The share of the week's capacity used so far, the mean over the accounts. Without the
        /// per-account list: what was used before today plus today.
        var weekPercent: Double {
            if let accounts = perAccount, !accounts.isEmpty {
                return accounts.reduce(0) { $0 + $1.percent } / Double(accounts.count)
            }
            return min(100, max(0, 100 - leftPercent + todayPercent))
        }
    }

    struct AccountWeek: Decodable, Hashable, Sendable {
        /// The share of its week's capacity used (the weekly limit, plus one per claimed reset).
        var percent: Double
    }

    /// An open week with a claimed reset: its use against its capacity (135 of 200).
    struct WeekCapacity: Decodable, Hashable, Sendable {
        var usedPercent: Double
        var capacityPercent: Double
        /// With one account: the share used in each stretch between resets ([95, 40]).
        var segments: [Double]?
        var resets: Int
    }

    var plans: [Plan]

    /// The plans with an open weekly limit, as This Week's Limit lists them.
    var weekly: [(plan: Plan, budget: Budget)] {
        plans.compactMap { plan in plan.budget.map { (plan, $0) } }
    }
}
