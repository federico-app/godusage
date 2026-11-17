import Foundation

/// Each plan's weekly windows, reset to reset: the share of the weekly limit used in each and on each
/// of its days, and its 5-hour sessions. Computed by the server from the quota windows it keeps for 13 months.
struct TeamPlanHistory: Decodable, Hashable, Sendable {
    struct Plan: Decodable, Hashable, Sendable {
        /// Plan ids change on every save, so a plan is also matched by provider and name.
        var id: String
        var provider: String
        var name: String
        /// Oldest first, the open week last.
        var weeks: [Week]
    }

    /// One of the plan's weekly windows, from reset to reset.
    struct Week: Decodable, Hashable, Sendable {
        /// The window's first and last calendar days.
        var from: String
        var to: String
        var startsAt: String
        var endsAt: String
        /// Still running.
        var open: Bool
        /// The share of the window's capacity used, the mean over its accounts. Without a claimed reset
        /// the capacity is the weekly limit.
        var percent: Double
        /// With a claimed reset that kept the reset time: the share of the weekly limit used in all
        /// (135), the capacity (200: a limit per claim plus one), and how many were claimed. Nil otherwise
        /// and from older servers.
        var usedPercent: Double?
        var capacityPercent: Double?
        var resets: Int?
        var estimated: Bool
        var accounts: Int
        var days: [Day]
        var sessions: Sessions?
    }

    struct Day: Decodable, Hashable, Sendable {
        var day: String
        /// The mean share of the weekly limit the accounts read that day used. Nil without data or after today.
        var percent: Double?
        var working: Bool
        var estimated: Bool
        var accounts: Int
        /// Resets claimed that day. Nil when none.
        var resets: Int?
    }

    struct Sessions: Decodable, Hashable, Sendable {
        var sessions: Int
        var limitHits: Int
        var averagePeakPercent: Double
    }

    var plans: [Plan]

    /// The weeks of a plan in the Plans report.
    func weeks(for plan: TeamPlanReport) -> [Week]? {
        (plans.first { $0.id == plan.id } ?? plans.first { $0.provider == plan.provider && $0.name == plan.name })?.weeks
    }

    static let defaultWeeks = 12
}

/// How much of the open weekly limit today can use and keep the week on pace: what was left at the
/// start of today, spread over today and the working days until the reset. Computed by the server.
struct TeamPlanBudget: Decodable, Hashable, Sendable {
    struct Day: Decodable, Hashable, Sendable {
        var day: String
        /// Nil without data and after today.
        var percent: Double?
        var working: Bool
        var estimated: Bool
        /// Resets claimed that day. Nil when none.
        var resets: Int?
    }

    /// An open week with a claimed reset that kept the reset time: what it used of its capacity.
    struct WeekCapacity: Decodable, Hashable, Sendable {
        /// The share of the weekly limit used in all, every stretch between claims counted (135).
        var usedPercent: Double
        /// 100 per limit: 100 plus 100 per claim (200).
        var capacityPercent: Double
        /// With one account: the share used before each claim, then since the last ([95, 40]).
        var segments: [Double]?
        var resets: Int
    }

    /// One account in the open week, from the server's names: who reads it ("You" first), how much
    /// of its week it used, and when it resets.
    struct AccountWeek: Decodable, Hashable, Sendable {
        var people: [String]
        /// The share of its week's capacity used (the weekly limit, plus one per claimed reset).
        var percent: Double
        /// With a claimed reset: the share of the weekly limit used in all, the capacity, and each stretch.
        var usedPercent: Double?
        var capacityPercent: Double?
        var segments: [Double]?
        var todayPercent: Double
        var resetsAt: String
        /// A Mac names it per Mac, so it may be the same login as another account here.
        var perDevice: Bool
        /// The account's key, which an owner hides it from the plan by. Owners only; nil from older servers.
        var account: String?
    }

    /// The share of the weekly limit used today.
    var todayPercent: Double
    /// What today can use and keep the week on pace.
    var affordablePercent: Double
    /// The share left at the start of today.
    var leftPercent: Double
    /// Today and the working days after it until the reset.
    var workingDaysLeft: Int
    var resetsAt: String
    var accounts: Int
    /// Each account with an open week, soonest reset first. Nil from servers before it.
    var perAccount: [AccountWeek]?
    /// The open week, day by day.
    var days: [Day]
    /// Set when a reset was claimed in an open week that kept its reset time. Nil otherwise and from older servers.
    var week: WeekCapacity?
    /// Today's budget over working hours, for Live Pace. Nil from servers before it, and on days the
    /// server can't tell (no time zone sent).
    var pace: TeamPlanPace?
}
