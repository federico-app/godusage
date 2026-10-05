import Foundation

/// Pure rules behind the team notifications, kept apart from `TeamsStore` so they are unit-tested.
enum TeamEvents {
    /// The window overtakes are judged on: the last 7 days by spend, steady enough not to flap.
    static let overtakeRange = StatsRange.week
    static let overtakeSort = StatsSort.cost

    /// Members ranked above `me` (strictly), by id.
    static func membersAbove(_ me: String, in stats: TeamStats) -> Set<String> {
        guard let mine = stats.members.first(where: { $0.userID == me }) else { return [] }
        return Set(stats.members.filter { $0.rank < mine.rank && $0.totals.value(for: overtakeSort) > 0 }.map(\.userID))
    }

    /// Who passed `me` since the last check. The first check (no previous snapshot) only records the
    /// baseline, so turning the alert on never fires for standings that were already there.
    static func newOvertakers(previousAbove: Set<String>?, stats: TeamStats, me: String) -> [TeamStats.Member] {
        guard let previousAbove else { return [] }
        let above = membersAbove(me, in: stats)
        return stats.members.filter { above.contains($0.userID) && !previousAbove.contains($0.userID) }
    }

    static func overtakeMessage(_ overtakers: [TeamStats.Member], team: String) -> (title: String, body: String) {
        let names = overtakers.map(\.displayName)
        let who = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return (
            "\(who) Passed You",
            "\(who) moved ahead of you in \(team) by spend over the last 7 days."
        )
    }

    // MARK: - Weekly recap

    /// The ISO calendar the weekly recap uses (weeks start on Monday).
    static var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// When a recap is due: from Monday 9:00 of a week that hasn't had one yet. Returns that week's
    /// key ("2026-W41") and the last day of the week being summarized (the Sunday before).
    static func weeklyRecapDue(now: Date, lastSentWeek: String?, calendar: Calendar = isoCalendar) -> (week: String, endDay: String)? {
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let releaseTime = calendar.date(byAdding: .hour, value: 9, to: monday),
              now >= releaseTime,
              let sunday = calendar.date(byAdding: .day, value: -1, to: monday)
        else { return nil }
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let week = String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
        guard week != lastSentWeek else { return nil }
        return (week, DailyUsageAccumulator.dayKey(from: sunday, calendar: calendar))
    }

    static func weeklyRecapMessage(stats: TeamStats, team: String, me: String) -> (title: String, body: String)? {
        guard let mine = stats.members.first(where: { $0.userID == me }) else { return nil }
        var parts: [String] = []
        if mine.totals.value(for: .cost) > 0 || mine.tokens > 0 {
            var standing = "You were #\(mine.rank) of \(stats.members.count) with \(TeamsFormat.value(mine.totals, sort: .cost))"
            if let change = mine.rankChange, change != 0 {
                standing += change > 0 ? ", up \(change)" : ", down \(-change)"
            }
            parts.append(standing + ".")
        } else {
            parts.append("You had no usage.")
        }
        if let leader = stats.members.first, leader.userID != me, leader.totals.costUSD > 0 {
            parts.append("\(leader.displayName) led with \(TeamsFormat.value(leader.totals, sort: .cost)).")
        }
        let myTopModel = stats.models
            .compactMap { model in model.members.first { $0.userID == me }.map { (model.model, $0.costUSD) } }
            .max { $0.1 < $1.1 }
        if let myTopModel, myTopModel.1 > 0 {
            parts.append("Your top model: \(myTopModel.0).")
        }
        return ("Last Week in \(team)", parts.joined(separator: " "))
    }
}
