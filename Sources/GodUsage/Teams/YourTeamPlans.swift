import Foundation

/// A plan with the team it comes from.
struct TeamPlanEntry: Hashable, Sendable, Identifiable {
    var teamID: String
    var plan: TeamPlanReport

    var id: String { "\(teamID)|\(plan.id)" }
}

/// The plans behind your weekly limit across every team you're in. The selected team shows its own
/// plans as they are; your other teams add only the plans that cover you, and only once per
/// subscription, since the same subscription can be set up as a plan in two teams.
enum YourTeamPlans {
    /// The selected team's plans first, unchanged, then the other teams' plans that cover you, in the
    /// order of `reports`, without the ones already there.
    static func merge(selectedTeamID: String?, reports: [(teamID: String, report: TeamPlansReport)]) -> [TeamPlanEntry] {
        var entries = reports.first { $0.teamID == selectedTeamID }.map { selected in
            selected.report.plans.map { TeamPlanEntry(teamID: selected.teamID, plan: $0) }
        } ?? []
        for (teamID, report) in reports where teamID != selectedTeamID {
            for plan in report.plans where plan.includesYou {
                let duplicate = entries.contains { $0.plan.includesYou && sameSubscription($0.plan, plan) }
                if !duplicate { entries.append(TeamPlanEntry(teamID: teamID, plan: plan)) }
            }
        }
        return entries
    }

    /// Two plans that both cover you stand for the same subscription when they're for one provider and
    /// either name the same plan (the detected plan when both are linked to one, else the name, ignoring
    /// case and spaces) or their open weekly limits reset at the same instant (one account's window,
    /// however each owner named the plan). Reports carry no account ids, so this is as close as the
    /// app gets; a false match only hides another team's copy, never the selected team's.
    static func sameSubscription(_ a: TeamPlanReport, _ b: TeamPlanReport) -> Bool {
        guard a.provider == b.provider else { return false }
        if let resetA = a.budget?.resetsAt, let resetB = b.budget?.resetsAt, resetA == resetB { return true }
        if let detectedA = a.detectedPlan, let detectedB = b.detectedPlan {
            return normalized(detectedA) == normalized(detectedB)
        }
        return normalized(a.name) == normalized(b.name)
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }
}

extension TeamPlansStore {
    /// `merge` over the reports loaded so far, the selected team first, then `teamIDs` in order.
    func yourPlans(selectedTeamID: String?, teamIDs: [String]) -> [TeamPlanEntry] {
        let ordered = (selectedTeamID.map { [$0] } ?? []) + teamIDs.filter { $0 != selectedTeamID }
        let reports = ordered.compactMap { teamID in report(teamID: teamID).map { (teamID: teamID, report: $0) } }
        return YourTeamPlans.merge(selectedTeamID: selectedTeamID, reports: reports)
    }

    /// Keeps every team's plans fresh enough for your weekly limit, at most one load per team every
    /// `maxAge` (`backgroundMaxAge`, or `livePaceMaxAge` with Live Pace on).
    func loadIfStale(teamIDs: [String], now: Date = Date(), maxAge: TimeInterval = backgroundMaxAge) async {
        for teamID in teamIDs { await loadIfStale(teamID: teamID, now: now, maxAge: maxAge) }
    }
}
