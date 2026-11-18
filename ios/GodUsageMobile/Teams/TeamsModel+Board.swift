import Foundation

/// A plan's last Live Pace state and the day it was seen.
struct PaceMemory: Hashable, Sendable {
    var day: String
    var state: LivePace.State
}

/// What the Team tab reads around the board, worked out the way the Mac's `TeamsSocialStore` and
/// `TeamPlansStore+LivePace` do.
extension TeamsModel {
    var selectedTeam: TeamSummary? {
        teams.first { $0.id == selectedTeamID } ?? teams.first
    }

    /// Today's top spender (the crown); nil before anyone spent today or on a tie.
    func topSpenderToday(teamID: String) -> String? {
        guard let board = todayBoards[teamID], let leader = board.members.first, leader.costUSD > 0,
              board.members.filter({ $0.rank == 1 }).count == 1
        else { return nil }
        return leader.userID
    }

    /// Last month's champion (the trophy), if that month had one.
    func lastMonthChampion(teamID: String) -> TeamChampion? {
        guard let latest = champions[teamID]?.first,
              let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        else { return nil }
        return latest.month == String(TeamsFormat.localToday(previousMonth).prefix(7)) ? latest : nil
    }

    /// The team's month-end projection, from this month's board.
    func projection(teamID: String) -> TeamProjection? {
        guard let board = monthBoards[teamID], let range = board.range else { return nil }
        return TeamProjection.make(spentSoFar: board.totals.costUSD, from: range.from, to: range.to)
    }

    /// Identifies a plan across saves (plan ids change on every save).
    static func paceKey(teamID: String, plan: TeamPlans.Plan) -> String {
        "\(teamID)|\(plan.provider)|\(plan.name)"
    }

    /// The plan's Live Pace at `now`, steadied by its last state today. Nil without pace data.
    func livePace(teamID: String, plan: TeamPlans.Plan, now: Date) -> LivePace? {
        guard let pace = plan.budget?.pace else { return nil }
        let memory = paceMemory[Self.paceKey(teamID: teamID, plan: plan)]
        let previous = memory?.day == TeamsFormat.localToday(now) ? memory?.state : nil
        return LivePace(pace: pace, now: now, previous: previous)
    }

    /// Records each plan's state, so the next minute's color keeps to it inside the thresholds' gap.
    func rememberPaces(teamID: String, now: Date) {
        let today = TeamsFormat.localToday(now)
        for entry in plans[teamID]?.weekly ?? [] {
            guard let live = livePace(teamID: teamID, plan: entry.plan, now: now) else { continue }
            let key = Self.paceKey(teamID: teamID, plan: entry.plan)
            if paceMemory[key] != PaceMemory(day: today, state: live.state) {
                paceMemory[key] = PaceMemory(day: today, state: live.state)
            }
        }
    }
}
