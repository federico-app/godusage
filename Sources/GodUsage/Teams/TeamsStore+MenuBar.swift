import Foundation

/// The menu bar's team segment (see `StatusItemImageUpdater`).
extension TeamsStore {
    /// Your rank, your share of the team's spend, and your spend today in the selected team, from the
    /// latest loaded stats; nil when off or not loaded yet. `rank` reads "#2 · 38%" (the share is
    /// left out while the team has spent nothing today).
    var menuBarStanding: (rank: String, spend: String)? {
        guard showRankInMenuBar, let teamID = selectedTeamID, let me = user?.id,
              let stats = cachedStats[StatsKey(teamID: teamID, range: .today, sort: .cost)],
              let mine = stats.members.first(where: { $0.userID == me })
        else { return nil }
        var rank = "#\(mine.rank)"
        if let share = Self.shareText(mine.costUSD, of: stats.totals.costUSD) { rank += " · \(share)" }
        return (rank, Formatters.currency(mine.costUSD))
    }

    /// "38%", or "<1%" for a sliver; nil when the team total is zero.
    static func shareText(_ part: Double, of total: Double) -> String? {
        guard total > 0 else { return nil }
        let percent = part / total * 100
        if percent > 0, percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }
}
