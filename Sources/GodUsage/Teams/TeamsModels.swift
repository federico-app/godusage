import Foundation

/// The wire types of the teams backend (`backend/`, documented in `docs/teams-backend.md`).

struct TeamsUser: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
}

enum TeamRole: String, Codable, Hashable, Sendable {
    case owner
    case member
}

struct TeamSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var role: TeamRole
    var memberCount: Int
}

struct TeamMember: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var role: TeamRole
    var joinedAt: String
}

struct TeamDetail: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var role: TeamRole
    var createdAt: String
    var inviteURL: URL
    /// Set only for the owner, and only while the read-only web leaderboard is shared.
    var publicBoardURL: URL?
    var members: [TeamMember]

    var summary: TeamSummary {
        TeamSummary(id: id, name: name, role: role, memberCount: members.count)
    }
}

struct InvitePreview: Codable, Hashable, Sendable {
    struct Team: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var memberCount: Int
    }

    var team: Team
    var alreadyMember: Bool
}

struct TeamsSession: Codable, Hashable, Sendable {
    var token: String
    var user: TeamsUser
}

enum StatsRange: String, CaseIterable, Codable, Hashable, Sendable {
    case today
    case week = "7d"
    case month = "30d"

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        }
    }
}

enum StatsSort: String, CaseIterable, Codable, Hashable, Sendable {
    case cost
    case tokens

    var label: String {
        switch self {
        case .cost: "Spend"
        case .tokens: "Tokens"
        }
    }
}

struct UsageTotals: Codable, Hashable, Sendable {
    var tokens: Int
    var costUSD: Double

    func value(for sort: StatsSort) -> Double {
        sort == .cost ? costUSD : Double(tokens)
    }
}

struct TeamStats: Codable, Hashable, Sendable {
    struct Range: Codable, Hashable, Sendable {
        var name: StatsRange
        var from: String
        var to: String
    }

    struct ProviderTotals: Codable, Hashable, Sendable, Identifiable {
        var provider: String
        var tokens: Int
        var costUSD: Double
        var id: String { provider }
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }
    }

    struct MemberTotals: Codable, Hashable, Sendable {
        var userID: String
        var tokens: Int
        var costUSD: Double
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }
    }

    struct Member: Codable, Hashable, Sendable, Identifiable {
        var userID: String
        var displayName: String
        var rank: Int
        var tokens: Int
        var costUSD: Double
        var providers: [ProviderTotals]
        var id: String { userID }
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }
    }

    struct Model: Codable, Hashable, Sendable, Identifiable {
        var model: String
        var provider: String
        var tokens: Int
        var costUSD: Double
        var members: [MemberTotals]
        var id: String { "\(provider)/\(model)" }
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }
    }

    struct Day: Codable, Hashable, Sendable, Identifiable {
        var day: String
        var members: [MemberTotals]
        var id: String { day }
    }

    var range: Range
    var sort: StatsSort
    var totals: UsageTotals
    var members: [Member]
    var providers: [ProviderTotals]
    var models: [Model]
    var daily: [Day]
}

struct TeamStatsResponse: Codable, Hashable, Sendable {
    struct Team: Codable, Hashable, Sendable {
        var id: String
        var name: String
    }

    var team: Team
    var stats: TeamStats
}
