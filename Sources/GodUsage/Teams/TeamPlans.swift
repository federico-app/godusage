import Foundation
import Observation

/// A subscription the team pays for, as the owner enters it.
struct TeamPlan: Codable, Hashable, Sendable, Identifiable {
    /// From `effectiveFrom` (a calendar day) the plan has `name` and `monthlyCostUSD`; before it, the
    /// previous terms. See `TeamPlanChanges.swift`.
    struct Change: Codable, Hashable, Sendable {
        var effectiveFrom: String
        var name: String
        var monthlyCostUSD: Double
        var previousName: String
        var previousMonthlyCostUSD: Double
    }

    var id: String = UUID().uuidString
    var provider: String
    /// The terms in effect today.
    var name: String
    var monthlyCostUSD: Double
    /// Day of the month the plan renews (29–31 fall on the last day of shorter months).
    var renewalDay: Int
    /// The members the plan covers. Nil covers every member.
    var memberIDs: [String]?
    /// The price history, past and future, in date order.
    var changes: [Change] = []
    /// The plan GodUsage detects that this plan stands for (e.g. "Max 20x").
    var detectedPlan: String?
    /// Detected plans the owner chose not to be told about for this plan.
    var ignoredPlans: [String] = []

    private enum CodingKeys: String, CodingKey {
        case provider, name, monthlyCostUSD, renewalDay, memberIDs, changes, detectedPlan, ignoredPlans
    }
}

/// A covered member whose Mac detects another plan than the one a team plan is linked to.
struct TeamPlanMismatch: Decodable, Hashable, Sendable {
    var userID: String
    var displayName: String
    var detectedPlan: String
    var detectedAt: String
    /// The member's local day when their Mac first detected it.
    var detectedOn: String
}

/// A member's latest detected plan for a provider. Owners only.
struct TeamDetectedPlan: Decodable, Hashable, Sendable {
    var userID: String
    var provider: String
    var plan: String
    var detectedAt: String
    var detectedOn: String
}

/// One plan in the Plans report: its cost against the covered members' usage of its provider at API
/// prices, in the plan's current billing cycle. Computed by the server.
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
    var memberIDs: [String]?
    /// Whether the plan covers the signed-in user.
    var includesYou: Bool
    var cycle: Cycle
    var valueUSD: Double
    var projectedValueUSD: Double
    var projectedMultiple: Double
    var underused: Bool
    // Optional: servers before plan changes don't send these.
    var changes: [TeamPlan.Change]?
    var detectedPlan: String?
    var ignoredPlans: [String]?
    /// What the cycle costs, each price prorated by the days it applies.
    var cycleCostUSD: Double?
    /// Covered members whose Mac detects another plan. Empty for members who don't own the team.
    var mismatches: [TeamPlanMismatch]?

    var cycleCost: Double { cycleCostUSD ?? monthlyCostUSD }

    var plan: TeamPlan {
        TeamPlan(
            id: id, provider: provider, name: name, monthlyCostUSD: monthlyCostUSD, renewalDay: renewalDay, memberIDs: memberIDs,
            changes: changes ?? [], detectedPlan: detectedPlan, ignoredPlans: ignoredPlans ?? []
        )
    }
}

struct TeamPlansReport: Decodable, Hashable, Sendable {
    struct Totals: Decodable, Hashable, Sendable {
        var monthlyCostUSD: Double
        var valueUSD: Double
        var projectedValueUSD: Double
        var cycleCostUSD: Double?
    }

    var plans: [TeamPlanReport]
    var totals: Totals
    var canEdit: Bool
    /// The members' latest detected plans, for the owner's Detected Plan picker. Owners only.
    var detectedPlans: [TeamDetectedPlan]?
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
    @ObservationIgnored private let changeAlertsEnabled: @MainActor () -> Bool
    @ObservationIgnored private let postNotification: @MainActor (_ id: String, _ title: String, _ subtitle: String, _ body: String) async -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    private static let notifiedMismatchesKey = "godusage.teams.notifiedPlanMismatches.v1"

    init(
        teams: TeamsStore,
        api: any TeamsAPI = TeamsAPIClient(),
        changeAlertsEnabled: @escaping @MainActor () -> Bool = { false },
        postNotification: @escaping @MainActor (String, String, String, String) async -> Bool = { _, _, _, _ in false },
        defaults: UserDefaults = .standard
    ) {
        self.teams = teams
        self.api = api
        self.changeAlertsEnabled = changeAlertsEnabled
        self.postNotification = postNotification
        self.defaults = defaults
        teams.afterUploadHooks.append { [weak self] in await self?.checkPlanMismatches() }
    }

    /// Tells an owner once about each new mismatch on a team they own: a covered member's Mac detects
    /// another plan than the one a plan is linked to. Mismatches already there the first time (or when
    /// the alert is turned back on) are only recorded, so it never announces old ones.
    func checkPlanMismatches() async {
        guard changeAlertsEnabled() else {
            defaults.removeObject(forKey: Self.notifiedMismatchesKey)
            return
        }
        let stored = defaults.stringArray(forKey: Self.notifiedMismatchesKey)
        var notified = Set(stored ?? [])
        for team in teams.teams where team.role == .owner {
            await load(teamID: team.id)
            for plan in report(teamID: team.id)?.plans ?? [] {
                for mismatch in plan.mismatches ?? [] {
                    let key = TeamPlanChanges.alertKey(teamID: team.id, provider: plan.provider, mismatch: mismatch)
                    guard notified.insert(key).inserted, stored != nil else { continue }
                    let message = TeamPlanChanges.mismatchMessage(mismatch, plan: plan)
                    _ = await postNotification("team-plan-change", "Plan Change Detected", team.name, message)
                }
            }
        }
        defaults.set(Array(notified), forKey: Self.notifiedMismatchesKey)
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
