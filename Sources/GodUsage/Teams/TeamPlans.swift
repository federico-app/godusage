import Foundation
import Observation

/// A subscription the team pays for, as the owner enters it.
struct TeamPlan: Codable, Hashable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var provider: String
    var name: String
    var monthlyCostUSD: Double
    /// Day of the month the plan renews (29–31 fall on the last day of shorter months).
    var renewalDay: Int

    private enum CodingKeys: String, CodingKey { case provider, name, monthlyCostUSD, renewalDay }
}

/// One plan in the Plans report: its cost against the team's usage of its provider at API prices,
/// in the plan's current billing cycle. Computed by the server.
struct TeamPlanReport: Decodable, Hashable, Sendable, Identifiable {
    struct Cycle: Decodable, Hashable, Sendable {
        var from: String
        var to: String
        var daysElapsed: Int
        var daysTotal: Int
        var daysLeft: Int
    }

    var id: String
    var provider: String
    var name: String
    var monthlyCostUSD: Double
    var renewalDay: Int
    var cycle: Cycle
    var valueUSD: Double
    var projectedValueUSD: Double
    var projectedMultiple: Double
    var underused: Bool

    var plan: TeamPlan {
        TeamPlan(id: id, provider: provider, name: name, monthlyCostUSD: monthlyCostUSD, renewalDay: renewalDay)
    }
}

struct TeamPlansReport: Decodable, Hashable, Sendable {
    struct Totals: Decodable, Hashable, Sendable {
        var monthlyCostUSD: Double
        var valueUSD: Double
        var projectedValueUSD: Double
    }

    var plans: [TeamPlanReport]
    var totals: Totals
    var canEdit: Bool
}

/// The team's plans and their report, per team. The owner edits the list in Settings → Teams; every
/// member sees the report in the Teams window.
@MainActor
@Observable
final class TeamPlansStore {
    private(set) var reportsByTeam: [String: TeamPlansReport] = [:]
    private(set) var errorMessage: String?
    private(set) var isSaving = false

    @ObservationIgnored private let teams: TeamsStore
    @ObservationIgnored private let api: any TeamsAPI

    init(teams: TeamsStore, api: any TeamsAPI = TeamsAPIClient()) {
        self.teams = teams
        self.api = api
    }

    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    /// Background loads for the dashboard's suggestions; the Plans tab always loads on open.
    static let backgroundMaxAge: TimeInterval = 30 * 60

    func report(teamID: String) -> TeamPlansReport? { reportsByTeam[teamID] }

    func load(teamID: String) async {
        guard let token = teams.sessionToken else { return }
        do {
            reportsByTeam[teamID] = try await api.plans(token: token, teamID: teamID, today: teams.localToday())
            loadedAt[teamID] = Date()
            errorMessage = nil
        } catch {
            AppLog.warn(.teams, "loading team plans failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Loads unless a report younger than `backgroundMaxAge` is already here. A failed load counts
    /// as an attempt too, so a down backend is retried at the same pace rather than every pass.
    func loadIfStale(teamID: String, now: Date = Date()) async {
        if let last = loadedAt[teamID], now.timeIntervalSince(last) < Self.backgroundMaxAge { return }
        loadedAt[teamID] = now
        await load(teamID: teamID)
    }

    /// Replaces the team's plans. Returns whether the server accepted them.
    @discardableResult
    func save(teamID: String, plans: [TeamPlan]) async -> Bool {
        guard let token = teams.sessionToken else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            reportsByTeam[teamID] = try await api.savePlans(token: token, teamID: teamID, plans: plans, today: teams.localToday())
            errorMessage = nil
            return true
        } catch {
            AppLog.warn(.teams, "saving team plans failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
    }
}
