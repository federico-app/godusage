import Foundation

/// The teams backend's social types: reactions, monthly champions, and challenges.

enum TeamReaction: String, Codable, CaseIterable, Hashable, Sendable {
    case fire
    case clap
    case clown

    var emoji: String {
        switch self {
        case .fire: "🔥"
        case .clap: "👏"
        case .clown: "🤡"
        }
    }

    var accessibilityName: String {
        switch self {
        case .fire: "Fire"
        case .clap: "Applause"
        case .clown: "Clown"
        }
    }
}

struct MemberReactions: Codable, Hashable, Sendable {
    var fire: Int
    var clap: Int
    var clown: Int
    /// The viewer's own reactions to this member today.
    var mine: [TeamReaction]

    static let none = MemberReactions(fire: 0, clap: 0, clown: 0, mine: [])

    func count(_ reaction: TeamReaction) -> Int {
        switch reaction {
        case .fire: fire
        case .clap: clap
        case .clown: clown
        }
    }

    var total: Int { fire + clap + clown }
}

struct TeamReactions: Codable, Hashable, Sendable {
    /// The UTC day the reactions belong to ("2026-10-07"; the backend keeps the `week` key for
    /// older apps). Reactions start clean every day at midnight UTC.
    var week: String
    var byMember: [String: MemberReactions]
}

/// A past month's top spender.
struct TeamChampion: Codable, Hashable, Sendable, Identifiable {
    var month: String
    var userID: String
    var displayName: String
    var costUSD: Double
    var id: String { month }

    /// "September 2026".
    var monthLabel: String {
        guard let date = TeamsFormat.date("\(month)-01") else { return month }
        // Some locales (Italian: "settembre 2026") lowercase month names; a row label starts capitalized.
        let label = date.formatted(.dateTime.month(.wide).year())
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

enum ChallengeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case lowestSpend = "lowest_spend"
    case mostModels = "most_models"
    case mostTokens = "most_tokens"
    case bestEfficiency = "best_efficiency"

    var title: String {
        switch self {
        case .lowestSpend: "Lowest Spend"
        case .mostModels: "Most Models"
        case .mostTokens: "Most Tokens"
        case .bestEfficiency: "Best Efficiency"
        }
    }

    var rule: String {
        switch self {
        case .lowestSpend: "Spend the least. Only members who spend something count."
        case .mostModels: "Use the most different models."
        case .mostTokens: "Use the most tokens."
        case .bestEfficiency: "Pay the least per million tokens, with at least 100K tokens."
        }
    }

    var symbol: String {
        switch self {
        case .lowestSpend: "leaf"
        case .mostModels: "square.grid.3x3"
        case .mostTokens: "flame"
        case .bestEfficiency: "gauge.with.dots.needle.67percent"
        }
    }

    func valueText(_ value: Double) -> String {
        switch self {
        case .lowestSpend: Formatters.currency(value)
        case .mostModels: value == 1 ? "1 model" : "\(Int(value)) models"
        case .mostTokens: TeamsFormat.tokens(Int(value))
        case .bestEfficiency: "\(Formatters.currency(value)) / 1M"
        }
    }
}

struct ChallengeStanding: Codable, Hashable, Sendable, Identifiable {
    var userID: String
    var displayName: String
    var rank: Int
    var value: Double
    var id: String { userID }
}

struct TeamChallenge: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: ChallengeKind
    var startsOn: String
    var endsOn: String
    var createdBy: String?
    var finished: Bool
    var daysLeft: Int
    var standings: [ChallengeStanding]
    var winners: [ChallengeStanding]

    var daysLeftText: String {
        daysLeft == 1 ? "Last day" : "\(daysLeft) days left"
    }
}
