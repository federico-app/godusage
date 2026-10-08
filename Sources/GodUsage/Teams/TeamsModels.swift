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
    /// The members-only web leaderboard (sign in with Apple in a browser). Optional so an older
    /// backend's responses still decode.
    var webBoardURL: URL?
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
    case year = "365d"
    /// The calendar month so far; used for the end-of-month projection, not offered in pickers.
    case monthToDate = "mtd"

    /// The ranges the pickers offer.
    static let pickerCases: [StatsRange] = [.today, .week, .month, .year]

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .year: "Year"
        case .monthToDate: "This Month"
        }
    }

    /// The period before this one, in words, for the movement arrows' tooltips and captions.
    var previousLabel: String {
        switch self {
        case .today: "yesterday"
        case .week: "the previous 7 days"
        case .month: "the previous 30 days"
        case .year: "the previous year"
        case .monthToDate: "the same days last month"
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

    /// Dollars per million tokens: what a member pays for the same amount of work. Nil without tokens.
    var costPerMillionTokens: Double? {
        tokens > 0 ? costUSD / Double(tokens) * 1_000_000 : nil
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

    struct Previous: Codable, Hashable, Sendable {
        var rank: Int
        var tokens: Int
        var costUSD: Double
    }

    struct Member: Codable, Hashable, Sendable, Identifiable {
        var userID: String
        var displayName: String
        var rank: Int
        var tokens: Int
        var costUSD: Double
        var providers: [ProviderTotals]
        /// The member in the period before (nil: no usage then, or an older backend).
        var previous: Previous?
        /// When any of the member's Macs last uploaded (ISO 8601); nil if none has, or an older backend.
        var lastSyncAt: String?
        /// The GodUsage version of that latest upload; nil from apps before 1.0.8, or an older backend.
        var appVersion: String?
        var id: String { userID }
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }

        /// Places gained (positive) or lost (negative) since the previous period; nil when the
        /// member had no usage then.
        var rankChange: Int? { previous.map { $0.rank - rank } }
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

    /// An account several members log into (one shared Cursor seat). It counts once in the team's
    /// totals, providers, days, and models, and in no member's: the provider does not split it.
    struct SharedAccount: Codable, Hashable, Sendable, Identifiable {
        var provider: String
        var tokens: Int
        var costUSD: Double
        var members: [String]
        var id: String { "\(provider)/\(members.joined(separator: ","))" }
        var totals: UsageTotals { UsageTotals(tokens: tokens, costUSD: costUSD) }
    }

    struct Day: Codable, Hashable, Sendable, Identifiable {
        var day: String
        var members: [MemberTotals]
        /// Optional so an older backend's responses still decode.
        var providers: [ProviderTotals]?
        var id: String { day }
    }

    var range: Range
    var sort: StatsSort
    var totals: UsageTotals
    var members: [Member]
    var providers: [ProviderTotals]
    var models: [Model]
    var daily: [Day]
    /// Optional so an older backend's responses still decode.
    var shared: [SharedAccount]?

    /// Who shares an account, by display name ("Andrea & Federico").
    func sharedMemberNames(_ account: SharedAccount) -> String {
        let names = account.members.compactMap { id in members.first { $0.userID == id }?.displayName }
        return ListFormatter.localizedString(byJoining: names)
    }
}

struct TeamStatsResponse: Codable, Hashable, Sendable {
    struct Team: Codable, Hashable, Sendable {
        var id: String
        var name: String
    }

    var team: Team
    var stats: TeamStats
    /// Optional so an older backend's responses still decode.
    var reactions: TeamReactions?
    var champions: [TeamChampion]?
    /// The boards asked for with `include`, by range (`today`, `mtd`).
    var extra: [String: TeamStats]?
    /// The server's daily database budget is spent: these stats stay as they are until midnight UTC.
    var paused: Bool?
}
