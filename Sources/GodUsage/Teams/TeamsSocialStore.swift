import Foundation
import Observation

/// The social side of Teams: reactions, challenges, challenge-result alerts, the end-of-month
/// projection, and today's leader. Reads the session and stats from `TeamsStore`.
@MainActor
@Observable
final class TeamsSocialStore {
    private(set) var challengesByTeam: [String: [TeamChallenge]] = [:]
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private let teams: TeamsStore
    @ObservationIgnored private let api: any TeamsAPI
    @ObservationIgnored private let challengeAlertsEnabled: @MainActor () -> Bool
    @ObservationIgnored private let postNotification: @MainActor (_ id: String, _ title: String, _ subtitle: String, _ body: String) async -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    private static let notifiedChallengesKey = "godusage.teams.notifiedChallenges.v1"

    init(
        teams: TeamsStore,
        api: any TeamsAPI = TeamsAPIClient(),
        challengeAlertsEnabled: @escaping @MainActor () -> Bool = { false },
        postNotification: @escaping @MainActor (String, String, String, String) async -> Bool = { _, _, _, _ in false },
        defaults: UserDefaults = .standard
    ) {
        self.teams = teams
        self.api = api
        self.challengeAlertsEnabled = challengeAlertsEnabled
        self.postNotification = postNotification
        self.defaults = defaults
        teams.afterUploadHooks.append { [weak self] in await self?.checkChallengeResults() }
    }

    func dismissError() { errorMessage = nil }

    // MARK: - Reactions

    func reactions(teamID: String, userID: String) -> MemberReactions {
        teams.reactionsByTeam[teamID]?.byMember[userID] ?? .none
    }

    /// Gives or takes back a reaction. Applied at once, then replaced by the server's counts.
    func toggle(_ reaction: TeamReaction, teamID: String, userID: String) async {
        guard let token = teams.sessionToken else { return }
        var current = reactions(teamID: teamID, userID: userID)
        let on = !current.mine.contains(reaction)
        if on {
            current.mine.append(reaction)
        } else {
            current.mine.removeAll { $0 == reaction }
        }
        apply(reaction: reaction, delta: on ? 1 : -1, to: &current)
        var week = teams.reactionsByTeam[teamID] ?? TeamReactions(week: "", byMember: [:])
        week.byMember[userID] = current
        teams.reactionsByTeam[teamID] = week
        do {
            teams.reactionsByTeam[teamID] = try await api.setReaction(token: token, teamID: teamID, userID: userID, reaction: reaction, on: on)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            AppLog.warn(.teams, "reaction failed: \(error.localizedDescription)")
        }
    }

    private func apply(reaction: TeamReaction, delta: Int, to value: inout MemberReactions) {
        switch reaction {
        case .fire: value.fire = max(0, value.fire + delta)
        case .clap: value.clap = max(0, value.clap + delta)
        case .clown: value.clown = max(0, value.clown + delta)
        }
    }

    // MARK: - Champions and today's leader

    /// Last month's champion (the 🏆 next to their name), if that month had one.
    func lastMonthChampion(teamID: String) -> TeamChampion? {
        guard let latest = teams.championsByTeam[teamID]?.first,
              let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        else { return nil }
        let key = DailyUsageAccumulator.dayKey(from: previousMonth, calendar: .current).prefix(7)
        return latest.month == key ? latest : nil
    }

    /// Today's top spender (the 👑), from the latest Today stats; nil before anyone spent today.
    func kingOfTheDay(teamID: String) -> TeamStats.Member? {
        guard let stats = teams.cachedStats[TeamsStore.StatsKey(teamID: teamID, range: .today, sort: .cost)],
              let leader = stats.members.first, leader.costUSD > 0,
              stats.members.filter({ $0.rank == 1 }).count == 1
        else { return nil }
        return leader
    }

    // MARK: - Projection

    /// "On pace for $X in October": spend so far this month, stretched to the whole month.
    func projection(teamID: String, userID: String? = nil) -> TeamProjection? {
        guard let stats = teams.cachedStats[TeamsStore.StatsKey(teamID: teamID, range: .monthToDate, sort: .cost)] else { return nil }
        let spent = userID.map { id in stats.members.first { $0.userID == id }?.costUSD ?? 0 } ?? stats.totals.costUSD
        return TeamProjection.make(spentSoFar: spent, from: stats.range.from, to: stats.range.to)
    }

    // MARK: - Challenges

    func challenges(teamID: String) -> [TeamChallenge] { challengesByTeam[teamID] ?? [] }

    func loadChallenges(teamID: String) async {
        guard let token = teams.sessionToken else { return }
        do {
            challengesByTeam[teamID] = try await api.challenges(token: token, teamID: teamID, today: teams.localToday())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createChallenge(teamID: String, kind: ChallengeKind, days: Int) async {
        guard let token = teams.sessionToken else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let challenge = try await api.createChallenge(token: token, teamID: teamID, kind: kind, days: days, today: teams.localToday())
            challengesByTeam[teamID, default: []].insert(challenge, at: 0)
            errorMessage = nil
            await loadChallenges(teamID: teamID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelChallenge(teamID: String, challengeID: String) async {
        guard let token = teams.sessionToken else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.deleteChallenge(token: token, teamID: teamID, challengeID: challengeID)
            challengesByTeam[teamID]?.removeAll { $0.id == challengeID }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Alerts once per finished challenge. Challenges already finished when the alert is first
    /// turned on are only recorded, so it never announces old results.
    func checkChallengeResults() async {
        guard challengeAlertsEnabled() else {
            defaults.removeObject(forKey: Self.notifiedChallengesKey)
            return
        }
        let stored = defaults.stringArray(forKey: Self.notifiedChallengesKey)
        var notified = Set(stored ?? [])
        for team in teams.teams {
            await loadChallenges(teamID: team.id)
            for challenge in challenges(teamID: team.id) where challenge.finished && !notified.contains(challenge.id) {
                notified.insert(challenge.id)
                guard stored != nil, let message = TeamProjection.challengeResultMessage(challenge, me: teams.user?.id) else { continue }
                _ = await postNotification("team-challenge", message.title, team.name, message.body)
            }
        }
        defaults.set(Array(notified), forKey: Self.notifiedChallengesKey)
    }
}

/// Pure helpers behind the projection and the challenge alert, unit-tested.
struct TeamProjection: Equatable {
    var spentSoFar: Double
    var projected: Double
    var monthName: String
    var daysLeft: Int

    /// Stretches the spend from `from` (the 1st) through `to` (today) over the whole month.
    static func make(spentSoFar: Double, from: String, to: String, calendar: Calendar = .current) -> TeamProjection? {
        // Day keys are plain calendar days: read them with the same calendar the month length comes
        // from, so a time zone offset can never shift the 1st into the previous month.
        let parse = { (key: String) -> (year: Int, month: Int, day: Int)? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
        }
        guard let start = parse(from), let end = parse(to), start.year == end.year, start.month == end.month,
              let firstOfMonth = calendar.date(from: DateComponents(year: start.year, month: start.month, day: 1)),
              let monthDays = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return nil }
        let daysSoFar = end.day - start.day + 1
        guard daysSoFar > 0 else { return nil }
        var monthName = Date.FormatStyle.dateTime.month(.wide)
        monthName.timeZone = calendar.timeZone
        return TeamProjection(
            spentSoFar: spentSoFar,
            projected: spentSoFar / Double(daysSoFar) * Double(monthDays),
            monthName: firstOfMonth.formatted(monthName),
            daysLeft: monthDays - daysSoFar
        )
    }

    static func challengeResultMessage(_ challenge: TeamChallenge, me: String?) -> (title: String, body: String)? {
        let winners = challenge.winners
        guard !winners.isEmpty else {
            return ("\(challenge.kind.title) Ended", "Nobody qualified this time.")
        }
        let names = winners.map { $0.userID == me ? "You" : $0.displayName }
        let who = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let value = challenge.kind.valueText(winners[0].value)
        let iWon = winners.contains { $0.userID == me }
        return (
            iWon ? "You Won \(challenge.kind.title)" : "\(who) Won \(challenge.kind.title)",
            "\(who) finished first with \(value)."
        )
    }
}
