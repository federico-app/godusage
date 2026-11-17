import Foundation

/// The menu bar's team segment (see `MenuBarTeamSegment` and `StatusItemImageUpdater`).
extension TeamsStore {
    /// Your rank, its movement since yesterday, your spend, and your share of the team's spend today
    /// in the selected team, from the latest loaded stats; nil when off or not loaded yet.
    var menuBarStanding: MenuBarTeamSegment.Standing? {
        guard showRankInMenuBar, let teamID = selectedTeamID, let me = user?.id,
              let stats = cachedStats[StatsKey(teamID: teamID, range: .today, sort: .cost)],
              let mine = stats.members.first(where: { $0.userID == me })
        else { return nil }
        return MenuBarTeamSegment.Standing(
            rank: mine.rank,
            rankChange: mine.rankChange,
            spendUSD: mine.costUSD,
            share: Self.shareText(mine.costUSD, of: stats.totals.costUSD),
            syncedAt: mine.lastSyncAt.flatMap(GodUsageISO8601.date(from:)) ?? lastUploadAt
        )
    }

    /// "38%", or "<1%" for a sliver; nil when the team total is zero.
    static func shareText(_ part: Double, of total: Double) -> String? {
        guard total > 0 else { return nil }
        let percent = part / total * 100
        if percent > 0, percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }
}

extension TeamPlansStore {
    /// Live Pace for the menu bar's team segment: the same plans and values This Week's Limit shows
    /// (the selected team's plans plus the plans that cover you in your other teams, `yourPlans`),
    /// restricted to the plans that cover you.
    func menuBarPaces(selectedTeamID: String?, teamIDs: [String], now: Date) -> [LivePace] {
        Self.menuBarPaces(yourPlans(selectedTeamID: selectedTeamID, teamIDs: teamIDs)) { livePace($0, now: now) }
    }

    nonisolated static func menuBarPaces(_ entries: [TeamPlanEntry], livePace: (TeamPlanEntry) -> LivePace?) -> [LivePace] {
        entries.filter(\.plan.includesYou).compactMap(livePace)
    }
}
