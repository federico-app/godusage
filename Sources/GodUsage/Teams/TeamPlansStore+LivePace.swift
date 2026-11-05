import Foundation

/// A plan's last Live Pace state and the day it was seen.
struct PaceMemory: Hashable, Sendable {
    var day: String
    var state: LivePace.State
}

extension TeamPlansStore {
    /// With Live Pace on, your other teams' plans reload at least this often (else `backgroundMaxAge`).
    static let livePaceMaxAge: TimeInterval = 5 * 60
    /// Uploads reload the plans for Live Pace at most this often.
    static let livePaceReloadInterval: TimeInterval = 60
    private static let notifiedPaceKey = "godusage.teams.notifiedPaceAlerts.v1"

    /// Whether the dashboard shows Live Pace (Customize → Team).
    static var livePaceShown: Bool {
        let defaults = UserDefaults.standard
        let strip = defaults.object(forKey: TeamDashboardPreferences.showWeekStripKey) as? Bool ?? true
        let live = defaults.object(forKey: TeamDashboardPreferences.showLivePaceKey) as? Bool ?? true
        return strip && live
    }

    /// Identifies a plan across saves (plan ids change on every save) for Live Pace's memory and alerts.
    static func paceKey(_ entry: TeamPlanEntry) -> String {
        "\(entry.teamID)|\(entry.plan.provider)|\(entry.plan.name)"
    }

    /// The plan's Live Pace at `now`, steadied by its last state today. Nil without pace data.
    func livePace(_ entry: TeamPlanEntry, now: Date = Date()) -> LivePace? {
        guard let pace = entry.plan.budget?.pace else { return nil }
        let memory = paceMemory[Self.paceKey(entry)]
        let previous = memory?.day == teams.localToday() ? memory?.state : nil
        return LivePace(pace: pace, now: now, previous: previous)
    }

    /// After an upload, reloads your teams' plans (at most once a minute) so Live Pace and its alerts
    /// follow your use while the popover is closed.
    func reloadForLivePace(now: Date = Date()) async {
        guard Self.livePaceShown || paceAlertAllowed(.slowDown) || paceAlertAllowed(.roomToSpare) else { return }
        if let lastPaceReload, now.timeIntervalSince(lastPaceReload) < Self.livePaceReloadInterval { return }
        lastPaceReload = now
        for team in teams.teams { await load(teamID: team.id) }
    }

    /// Records each plan's state and sends the Live Pace alerts that are due: at most one of each kind
    /// per plan per day, only for plans that cover you, and only during your working hours.
    func refreshPaces(now: Date = Date()) async {
        let today = teams.localToday()
        let entries = yourPlans(selectedTeamID: teams.selectedTeamID, teamIDs: teams.teams.map(\.id))
        var notified = Set((defaults.stringArray(forKey: Self.notifiedPaceKey) ?? []).filter { $0.hasPrefix(today) })
        for entry in entries {
            guard let live = livePace(entry, now: now) else { continue }
            paceMemory[Self.paceKey(entry)] = PaceMemory(day: today, state: live.state)
            guard entry.plan.includesYou else { continue }
            let yourHours = (report(teamID: entry.teamID)?.yourHours ?? []).compactMap(\.interval)
            guard let alert = live.alert(inYourHours: yourHours.contains { $0.contains(now) }), paceAlertAllowed(alert) else { continue }
            let key = "\(today)|\(Self.paceKey(entry))|\(alert.rawValue)"
            guard notified.insert(key).inserted else { continue }
            let resetsAt = entry.plan.budget?.pace.flatMap { GodUsageISO8601.date(from: $0.resetsAt) }
            let message = live.alertMessage(alert, plan: entry.plan.name, resetsAt: resetsAt, nextDays: LivePaceFormat.days(live.futureDays.map(\.day)))
            let team = teams.teams.first { $0.id == entry.teamID }?.name ?? ""
            AppLog.info(.teams, "Live Pace \(alert.rawValue) for \(entry.plan.name)")
            _ = await postNotification("team-live-pace", message.title, team, message.body)
        }
        defaults.set(Array(notified), forKey: Self.notifiedPaceKey)
    }
}
