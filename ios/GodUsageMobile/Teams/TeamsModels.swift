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
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        }
    }
}

/// The parts of a team's stats the phone shows: totals and the ranked members.
struct TeamBoard: Decodable, Hashable, Sendable {
    struct Member: Decodable, Hashable, Identifiable, Sendable {
        var userID: String
        var displayName: String
        var rank: Int
        var tokens: Int
        var costUSD: Double
        var lastSyncAt: String?
        var id: String { userID }
    }

    var totals: UsageTotals
    var members: [Member]
}

/// Display formatting for team numbers and names.
enum TeamsFormat {
    static func cost(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(value >= 1_000 ? 0 : 2)))
    }

    /// Counts below a million print in full with thousands separators ("58,342"); larger ones
    /// stay compact ("1.2M", "3.4B") so rows don't overflow.
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch abs(number) {
        case 1_000_000_000...: return String(format: "%.1fB", number / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", number / 1_000_000)
        default: return value.formatted(.number)
        }
    }

    /// Provider ids as the Mac shows them, for the common ones; others are capitalized.
    static func providerName(_ id: String) -> String {
        let known = ["claude": "Claude", "codex": "Codex", "cursor": "Cursor", "grok": "Grok", "devin": "Devin", "copilot": "Copilot", "gemini": "Gemini", "opencode": "OpenCode"]
        return known[id] ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The viewer's local calendar day, as the server's `today` parameter.
    static func localToday(_ date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func syncAge(_ iso: String?) -> String? {
        guard let iso, let date = try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) else { return nil }
        return "Updated \(date.formatted(.relative(presentation: .named)))"
    }
}
