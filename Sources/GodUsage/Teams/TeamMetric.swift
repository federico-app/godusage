import Foundation

/// What the dashboard's Team section ranks by. It follows the Total Spend card's metric menu (Cost,
/// Cost/MTok, Tokens), so the popover has one metric choice. The Teams window maps its own Spend and
/// Tokens picker onto `spend` and `tokens`.
enum TeamMetric: Hashable, Sendable {
    case spend
    case costPerMtok
    case tokens

    init(_ metric: TotalSpendMetric) {
        switch metric {
        case .cost: self = .spend
        case .costPerMtok: self = .costPerMtok
        case .tokens: self = .tokens
        }
    }

    init(_ sort: StatsSort) {
        self = sort == .cost ? .spend : .tokens
    }

    /// The server ranking to fetch. Cost/MTok divides the Spend board's dollars by its tokens (every
    /// board carries both), then re-ranks on the Mac.
    var sort: StatsSort { self == .tokens ? .tokens : .cost }

    var teamLabel: String {
        switch self {
        case .spend: "team spend"
        case .costPerMtok: "team cost per 1M tokens"
        case .tokens: "team tokens"
        }
    }

    /// The number bars and ranks compare. Usage with no tokens has no rate, so it counts as zero.
    func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .spend: totals.costUSD
        case .costPerMtok: totals.costPerMillionTokens ?? 0
        case .tokens: Double(totals.tokens)
        }
    }

    func format(_ totals: UsageTotals) -> String {
        switch self {
        case .spend: Formatters.currency(totals.costUSD)
        case .costPerMtok: TeamsFormat.perMillion(totals) ?? "—"
        case .tokens: TeamsFormat.tokens(totals.tokens)
        }
    }

    /// A row's provider split, scaled so the segments add up to the row's value. Rates do not add
    /// across providers, so Cost/MTok splits the row's rate by each provider's share of its spend.
    func barSegments(_ providers: [TeamStats.ProviderTotals], total: UsageTotals) -> [TeamStats.ProviderTotals] {
        guard self == .costPerMtok else { return providers }
        let rate = value(total)
        guard total.costUSD > 0 else { return [] }
        return providers.map { provider in
            var scaled = provider
            scaled.costUSD = provider.costUSD / total.costUSD * rate
            return scaled
        }
    }

    /// Members largest first, with dense ranks. Spend and Tokens keep the server's ranks; Cost/MTok
    /// ranks here, and members without a rate go last.
    func ranked(_ members: [TeamStats.Member]) -> [TeamStats.Member] {
        guard self == .costPerMtok else { return members }
        var sorted = members.sorted { value($0.totals) > value($1.totals) || (value($0.totals) == value($1.totals) && $0.displayName < $1.displayName) }
        for index in sorted.indices {
            let previous = index > 0 ? sorted[index - 1] : nil
            sorted[index].rank = previous.map { value($0.totals) == value(sorted[index].totals) ? $0.rank : $0.rank + 1 } ?? 1
        }
        return sorted
    }
}
