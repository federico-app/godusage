import Foundation
import os

/// Who is spending fast right now: spend in the last hour and 0–3 bolts (`backend/src/momentum.ts`).
struct TeamMomentum: Decodable, Hashable, Sendable {
    var lastHourUSD: Double
    var level: Int

    /// Active now: spent something in the last hour.
    var isActive: Bool { lastHourUSD > 0 || level > 0 }
}

/// A month's top spender (the trophy next to their name).
struct TeamChampion: Decodable, Hashable, Sendable {
    /// "2026-10".
    var month: String
    var userID: String

    /// "October 2026" / "ottobre 2026".
    var monthLabel: String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]) else { return month }
        return "\(TeamsFormat.monthName(parts[1])) \(parts[0])"
    }
}

/// `GET /v1/teams/:id/stats`: the board, plus what the Team tab shows around it. Everything but
/// `stats` is an extra: a missing or unreadable one is left out (logged), never the whole board.
struct TeamStatsResponse: Decodable, Sendable {
    var stats: TeamBoard
    /// By user id; members with no spend in the last hour are missing.
    var momentum: [String: TeamMomentum]
    /// Newest month first.
    var champions: [TeamChampion]
    /// The boards asked for with `include` (`today`, `mtd`).
    var extra: [String: TeamBoard]

    private enum CodingKeys: String, CodingKey { case stats, momentum, champions, extra }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stats = try container.decode(TeamBoard.self, forKey: .stats)
        momentum = Self.optional(container, .momentum) ?? [:]
        champions = Self.optional(container, .champions) ?? []
        extra = Self.optional(container, .extra) ?? [:]
    }

    private static func optional<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? {
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            Logger(subsystem: "com.montinovo.godusage.mobile", category: "teams")
                .error("dropped an unreadable stats \(key.stringValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// "Team on pace for $X in November": the month's spend so far, stretched to the whole month.
struct TeamProjection: Equatable {
    var projected: Double
    var monthName: String
    var daysLeft: Int

    /// From the Month to Date board: `from` is the 1st, `to` today.
    static func make(spentSoFar: Double, from: String, to: String, calendar: Calendar = .current) -> TeamProjection? {
        let parse = { (key: String) -> [Int]? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? parts : nil
        }
        guard let start = parse(from), let end = parse(to), start[0] == end[0], start[1] == end[1],
              let firstOfMonth = calendar.date(from: DateComponents(year: start[0], month: start[1], day: 1)),
              let monthDays = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return nil }
        let daysSoFar = end[2] - start[2] + 1
        guard daysSoFar > 0 else { return nil }
        return TeamProjection(
            projected: spentSoFar / Double(daysSoFar) * Double(monthDays),
            monthName: TeamsFormat.monthName(start[1]),
            daysLeft: monthDays - daysSoFar
        )
    }
}

extension TeamsFormat {
    /// "November" / "novembre", standalone, in the app's language.
    static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = dateLocale
        let symbols = formatter.standaloneMonthSymbols ?? []
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : "\(month)"
    }
}

/// The user's own spend for a period, from `/v1/me/usage`.
struct UsagePeriodTotal: Equatable {
    var costUSD: Double
    var tokens: Int
    /// Spend per provider, largest first; nil when the server didn't send a split for these days.
    var providers: [ProviderTotals]?
}

extension MyUsage {
    /// The period's days: the last `dayCount` days ending `offset` days before today.
    func days(for period: BoardRange) -> [Day] {
        let end = days.count - period.offset
        guard end > 0 else { return [] }
        return Array(days[max(0, end - period.dayCount)..<end])
    }

    func total(for period: BoardRange) -> UsagePeriodTotal {
        let days = days(for: period)
        let cost = days.reduce(0) { $0 + $1.costUSD }
        let tokens = days.reduce(0) { $0 + $1.tokens }
        // Older servers send the split for the whole 30 days only.
        guard days.allSatisfy({ $0.providers != nil }) else {
            return UsagePeriodTotal(costUSD: cost, tokens: tokens, providers: period == .month ? providers.map {
                ProviderTotals(provider: $0.provider, tokens: $0.tokens, costUSD: $0.costUSD)
            } : nil)
        }
        var byProvider: [String: ProviderTotals] = [:]
        for day in days {
            for provider in day.providers ?? [] {
                var total = byProvider[provider.provider] ?? ProviderTotals(provider: provider.provider, tokens: 0, costUSD: 0)
                total.tokens += provider.tokens
                total.costUSD += provider.costUSD
                byProvider[provider.provider] = total
            }
        }
        let ranked = byProvider.values.sorted { $0.costUSD > $1.costUSD || ($0.costUSD == $1.costUSD && $0.provider < $1.provider) }
        return UsagePeriodTotal(costUSD: cost, tokens: tokens, providers: ranked)
    }
}
