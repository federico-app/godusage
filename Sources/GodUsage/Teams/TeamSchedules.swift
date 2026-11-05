import Foundation

/// A member's working hours, in their own time zone: the weekdays they work (ISO, 1 = Monday) and, on
/// each, from `start` to `end` (minutes after midnight), less an optional break. Live Pace spreads
/// today's budget over them.
struct TeamSchedule: Codable, Hashable, Sendable {
    var days: [Int]
    var start: Int
    var end: Int
    var breakStart: Int?
    var breakEnd: Int?

    static let standard = TeamSchedule(days: [1, 2, 3, 4, 5], start: 9 * 60, end: 18 * 60)

    var hasBreak: Bool { breakStart != nil && breakEnd != nil }

    /// Hours worked in a week.
    var weeklyHours: Double {
        let breakMinutes = hasBreak ? (breakEnd! - breakStart!) : 0
        return Double((end - start - breakMinutes) * days.count) / 60
    }

    /// What the server would refuse, said for the person fixing it; nil when it's fine.
    var problem: String? {
        if days.isEmpty { return "Pick at least one working day." }
        if end <= start { return "The working hours must end after they start." }
        if let breakStart, let breakEnd, breakStart <= start || breakEnd >= end || breakEnd <= breakStart {
            return "The break must fall inside the working hours."
        }
        return nil
    }

    /// "9:00", from minutes after midnight.
    static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Every member's working hours in a team, from the server.
struct TeamSchedules: Decodable, Hashable, Sendable {
    struct Member: Decodable, Hashable, Sendable, Identifiable {
        var userID: String
        var displayName: String
        var schedule: TeamSchedule
        /// Never set: the team's working days, 9:00 to 18:00.
        var isDefault: Bool
        /// The member's Mac's time zone; nil until it uploads with one.
        var timeZone: String?

        var id: String { userID }
    }

    var defaultSchedule: TeamSchedule
    var canEditOthers: Bool
    var members: [Member]
}

extension TeamPlansStore {
    func schedules(teamID: String) -> TeamSchedules? { schedulesByTeam[teamID] }

    func loadSchedules(teamID: String) async {
        guard let token = teams.sessionToken else { return }
        do {
            schedulesByTeam[teamID] = try await api.schedules(token: token, teamID: teamID)
            scheduleError = nil
        } catch {
            AppLog.warn(.teams, "loading working hours failed: \(error.localizedDescription)")
            scheduleError = error.localizedDescription
        }
    }

    /// Saves a member's hours (nil goes back to the team default), then reloads the hours and the
    /// team's plans, whose Live Pace moves with them. Returns whether the server accepted them.
    @discardableResult
    func saveSchedule(teamID: String, userID: String, schedule: TeamSchedule?) async -> Bool {
        guard let token = teams.sessionToken else { return false }
        do {
            try await api.saveSchedule(token: token, teamID: teamID, userID: userID, schedule: schedule)
            scheduleError = nil
        } catch {
            AppLog.warn(.teams, "saving working hours failed: \(error.localizedDescription)")
            scheduleError = error.localizedDescription
            return false
        }
        await loadSchedules(teamID: teamID)
        await load(teamID: teamID)
        return true
    }
}
