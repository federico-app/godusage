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

    /// `detectedPlan` goes out as an explicit null when unlinked: the server keeps a stored link when
    /// the field is missing (saves from apps before plan changes).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(name, forKey: .name)
        try container.encode(monthlyCostUSD, forKey: .monthlyCostUSD)
        try container.encode(renewalDay, forKey: .renewalDay)
        try container.encodeIfPresent(memberIDs, forKey: .memberIDs)
        try container.encode(changes, forKey: .changes)
        try container.encode(detectedPlan, forKey: .detectedPlan)
        try container.encode(ignoredPlans, forKey: .ignoredPlans)
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

/// How much of a plan's quota its covered accounts use in the cycle: the mean share of their quota
/// windows (Claude and Codex weekly, Cursor's cycle). Per plan, never per member: one account can
/// be shared.
struct TeamPlanQuota: Decodable, Hashable, Sendable {
    var usedPercent: Double
    var accounts: Int
    var windows: Int
    /// Windows last read well before they reset, so their share is a lower bound.
    var estimatedWindows: Int
    var wastedUSD: Double
}

/// How much of the weekly limit a plan's accounts use per day, over the last seven days.
struct TeamPlanDaily: Decodable, Hashable, Sendable {
    struct Day: Decodable, Hashable, Sendable {
        var day: String
        /// The mean share of the weekly limit the accounts read that day used. Nil without data.
        var percent: Double?
        var working: Bool
        /// Part of the share was spread over days no Mac read the window.
        var estimated: Bool
    }

    /// Today (not over yet) last.
    var days: [Day]
    /// The mean share per finished working day of the chart. Nil until one has data.
    var averagePercent: Double?
    /// The share per working day that uses exactly the whole week.
    var pacePercent: Double
    var accounts: Int
}

/// How a plan's accounts use their 5-hour sessions in the cycle.
struct TeamPlanSessions: Decodable, Hashable, Sendable {
    var sessions: Int
    var limitHits: Int
    var averagePeakPercent: Double
    /// Each session's peak, oldest first (the latest ones).
    var peaks: [Double]
    var accounts: Int
}

/// One plan in the Plans report: its cost against the covered members' usage of its provider at API
/// prices, and the share of its quota they use, in the plan's current billing cycle. Computed by the server.
struct TeamPlanReport: Decodable, Hashable, Sendable, Identifiable {
    struct Cycle: Decodable, Hashable, Sendable {
        var from: String
        var to: String
        var daysElapsed: Int
        var daysTotal: Int
        var daysLeft: Int
        // Optional: older servers don't send them.
        var workingDaysElapsed: Int?
        var workingDaysLeft: Int?
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
    /// Under half its quota on pace; without quota data, worth less than it costs.
    var underused: Bool
    /// Nil for providers GodUsage reads no quota for, until a covered Mac reports one, and from
    /// older servers.
    var quota: TeamPlanQuota?
    /// Nil until a covered Mac reports daily readings of a weekly window, and from older servers.
    var daily: TeamPlanDaily?
    /// Nil until a covered Mac reports a session, and from older servers.
    var sessions: TeamPlanSessions?
    /// Nil until a covered account has an open weekly window, and from older servers.
    var budget: TeamPlanBudget?
    /// Covered accounts a Mac could only name per Mac: one used on several Macs counts more than
    /// once, so the quota figures may be off. Nil from older servers.
    var perDeviceAccounts: Int?
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
        /// The quota share across the plans that have one, weighted by what each cycle costs.
        var quota: Quota?
    }

    struct Quota: Decodable, Hashable, Sendable {
        var usedPercent: Double
        var cycleCostUSD: Double
        var wastedUSD: Double
    }

    var plans: [TeamPlanReport]
    var totals: Totals
    var canEdit: Bool
    /// The members' latest detected plans, for the owner's Detected Plan picker. Owners only.
    var detectedPlans: [TeamDetectedPlan]?
    /// The team's working days (ISO weekdays, 1 = Monday), which pace the forecasts. Nil from older servers.
    var workingDays: [Int]?
    /// Your working hours today, for Live Pace's alerts. Nil from older servers.
    var yourHours: [TeamPlanPace.Span]?

    static let defaultWorkingDays = [1, 2, 3, 4, 5]
}

/// The team's plans and their report, per team. The owner edits the list in Settings → Teams; every
/// member sees the report in the Teams window.
@MainActor
@Observable
final class TeamPlansStore {
    private(set) var reportsByTeam: [String: TeamPlansReport] = [:]
    /// Loaded when a plan's Weekly History is first opened, and again with each report load.
    private(set) var historyByTeam: [String: TeamPlanHistory] = [:]
    private(set) var historyErrorByTeam: [String: String] = [:]
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    /// Every member's working hours, per team, for Settings → Teams → Members (see TeamSchedules.swift).
    var schedulesByTeam: [String: TeamSchedules] = [:]
    var scheduleError: String?
    /// Each plan's last Live Pace state today, so its color doesn't flicker at a threshold (see TeamPlansStore+LivePace).
    var paceMemory: [String: PaceMemory] = [:]

    @ObservationIgnored let teams: TeamsStore
    @ObservationIgnored let api: any TeamsAPI
    @ObservationIgnored let paceAlertAllowed: @MainActor (LivePace.Alert) -> Bool
    @ObservationIgnored var lastPaceReload: Date?
    @ObservationIgnored private let changeAlertsEnabled: @MainActor () -> Bool
    @ObservationIgnored let postNotification: @MainActor (_ id: String, _ title: String, _ subtitle: String, _ body: String) async -> Bool
    @ObservationIgnored let defaults: UserDefaults
    private static let notifiedMismatchesKey = "godusage.teams.notifiedPlanMismatches.v1"

    init(
        teams: TeamsStore,
        api: any TeamsAPI = TeamsAPIClient(),
        changeAlertsEnabled: @escaping @MainActor () -> Bool = { false },
        paceAlertAllowed: @escaping @MainActor (LivePace.Alert) -> Bool = { _ in false },
        postNotification: @escaping @MainActor (String, String, String, String) async -> Bool = { _, _, _, _ in false },
        defaults: UserDefaults = .standard
    ) {
        self.teams = teams
        self.api = api
        self.changeAlertsEnabled = changeAlertsEnabled
        self.paceAlertAllowed = paceAlertAllowed
        self.postNotification = postNotification
        self.defaults = defaults
        teams.afterUploadHooks.append { [weak self] in await self?.checkPlanMismatches() }
        teams.afterUploadHooks.append { [weak self] in await self?.reloadForLivePace() }
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

    @ObservationIgnored var loadedAt: [String: Date] = [:]
    /// Background loads for the dashboard's suggestions; the Plans tab always loads on open.
    static let backgroundMaxAge: TimeInterval = 30 * 60

    func report(teamID: String) -> TeamPlansReport? { reportsByTeam[teamID] }

    func load(teamID: String) async {
        guard let token = teams.sessionToken else { return }
        do {
            reportsByTeam[teamID] = try await api.plans(token: token, teamID: teamID, today: teams.localToday())
            loadedAt[teamID] = Date()
            errorMessage = nil
            await refreshPaces()
        } catch {
            AppLog.warn(.teams, "loading team plans failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        if historyByTeam[teamID] != nil { await loadHistory(teamID: teamID) }
    }

    func history(teamID: String) -> TeamPlanHistory? { historyByTeam[teamID] }
    func historyError(teamID: String) -> String? { historyErrorByTeam[teamID] }

    /// The team's plans' last `weeks` weeks, for their Weekly History.
    func loadHistory(teamID: String, weeks: Int = TeamPlanHistory.defaultWeeks) async {
        guard let token = teams.sessionToken else { return }
        do {
            historyByTeam[teamID] = try await api.planHistory(token: token, teamID: teamID, today: teams.localToday(), weeks: weeks)
            historyErrorByTeam[teamID] = nil
        } catch {
            AppLog.error(.teams, "loading team plan history failed: \(error.localizedDescription)")
            historyErrorByTeam[teamID] = error.localizedDescription
        }
    }

    /// Loads unless a report younger than `backgroundMaxAge` is already here. A failed load counts
    /// as an attempt too, so a down backend is retried at the same pace rather than every pass.
    func loadIfStale(teamID: String, now: Date = Date(), maxAge: TimeInterval = backgroundMaxAge) async {
        if let last = loadedAt[teamID], now.timeIntervalSince(last) < maxAge { return }
        loadedAt[teamID] = now
        await load(teamID: teamID)
    }

    /// Replaces the team's plans, and its working days when given. Returns whether the server accepted them.
    @discardableResult
    func save(teamID: String, plans: [TeamPlan], workingDays: [Int]? = nil) async -> Bool {
        guard let token = teams.sessionToken else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            reportsByTeam[teamID] = try await api.savePlans(
                token: token, teamID: teamID, plans: plans, workingDays: workingDays, today: teams.localToday()
            )
            errorMessage = nil
            return true
        } catch {
            AppLog.warn(.teams, "saving team plans failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
    }
}
