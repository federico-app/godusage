import Foundation

/// Each plan's calendar weeks of its weekly limit: the share used each day, the week's total, and its
/// 5-hour sessions. Computed by the server from the quota windows it keeps for 13 months.
struct TeamPlanHistory: Decodable, Hashable, Sendable {
    struct Plan: Decodable, Hashable, Sendable {
        /// Plan ids change on every save, so a plan is also matched by provider and name.
        var id: String
        var provider: String
        var name: String
        /// Oldest first, today's week last.
        var weeks: [Week]
    }

    struct Week: Decodable, Hashable, Sendable {
        /// The Monday.
        var from: String
        /// Monday to Sunday.
        var days: [Day]
        /// The sum of the days' shares. Nil when no day has data.
        var totalPercent: Double?
        var estimated: Bool
        var accounts: Int
        var sessions: Sessions?
    }

    struct Day: Decodable, Hashable, Sendable {
        var day: String
        /// The mean share of the weekly limit the accounts read that day used. Nil without data or after today.
        var percent: Double?
        var working: Bool
        var estimated: Bool
        var accounts: Int
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
