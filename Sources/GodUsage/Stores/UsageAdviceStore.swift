import Foundation
import Observation

/// Feeds `UsageAdvisor` from this Mac's quotas and reset credits and the selected team's plans,
/// remembers which suggestions the user dismissed, and posts the optional notification.
@MainActor
@Observable
final class UsageAdviceStore {
    /// Quota windows long enough that letting them reset unused wastes something.
    static let quotaKeys: Set<String> = ["weekly", "totalUsage"]
    /// Windows a reset credit restores; either one spent makes a credit worth claiming.
    static let claimableKeys: Set<String> = ["session", "weekly"]

    private(set) var dismissedIDs: [String]
    @ObservationIgnored private var notifiedIDs: [String]

    @ObservationIgnored private let registry: WidgetRegistry
    @ObservationIgnored private let dataStore: WidgetDataStore
    @ObservationIgnored private let isEnabled: @MainActor (String) -> Bool
    @ObservationIgnored private let displayName: @MainActor (String) -> String
    @ObservationIgnored private let teams: TeamsStore
    @ObservationIgnored private let plans: TeamPlansStore
    @ObservationIgnored private let settings: NotificationSettingsStore
    @ObservationIgnored private let defaults: UserDefaults

    private static let dismissedKey = "godusage.usageSuggestions.dismissed.v1"
    private static let notifiedKey = "godusage.usageSuggestions.notified.v1"
    /// Old ids fall off the end; a situation's id never comes back once its window has passed.
    private static let memoryLimit = 100

    init(
        registry: WidgetRegistry, dataStore: WidgetDataStore,
        isEnabled: @escaping @MainActor (String) -> Bool,
        displayName: @escaping @MainActor (String) -> String,
        teams: TeamsStore, plans: TeamPlansStore, settings: NotificationSettingsStore,
        defaults: UserDefaults = .standard
    ) {
        self.registry = registry
        self.dataStore = dataStore
        self.isEnabled = isEnabled
        self.displayName = displayName
        self.teams = teams
        self.plans = plans
        self.settings = settings
        self.defaults = defaults
        self.dismissedIDs = defaults.stringArray(forKey: Self.dismissedKey) ?? []
        self.notifiedIDs = defaults.stringArray(forKey: Self.notifiedKey) ?? []
    }

    /// Every current suggestion, most urgent first, without the dismissed ones.
    func suggestions(now: Date = Date()) -> [UsageSuggestion] {
        let dismissed = Set(dismissedIDs)
        return UsageAdvisor.suggestions(quotas: quotas(), resets: resets(now: now), plans: teamPlans(), now: now)
            .filter { !dismissed.contains($0.id) }
    }

    func dismiss(_ suggestion: UsageSuggestion) {
        dismissedIDs = Self.remember(suggestion.id, in: dismissedIDs)
        defaults.set(dismissedIDs, forKey: Self.dismissedKey)
    }

    /// Called after each refresh pass: keeps the team's plans fresh enough for the advice, and
    /// notifies about the top suggestion once per situation when the setting is on.
    func evaluate(now: Date = Date()) async {
        if teams.isSignedIn, let teamID = teams.selectedTeamID {
            await plans.loadIfStale(teamID: teamID, now: now)
        }
        guard settings.usageSuggestions, let top = suggestions(now: now).first,
              !notifiedIDs.contains(top.id) else { return }
        // Remember before posting: a denied permission must not retry the same advice every pass.
        notifiedIDs = Self.remember(top.id, in: notifiedIDs)
        defaults.set(notifiedIDs, forKey: Self.notifiedKey)
        await AppNotifications.shared.post(
            idPrefix: "usage-suggestion", title: top.title, subtitle: "", body: top.message,
            replacingIdentifier: "godusage-usage-suggestion"
        )
    }

    private static func remember(_ id: String, in list: [String]) -> [String] {
        Array((list.filter { $0 != id } + [id]).suffix(memoryLimit))
    }

    // MARK: - Inputs

    private func enabledDescriptors() -> [WidgetDescriptor] {
        registry.descriptors.filter { isEnabled($0.providerID) && !dataStore.loginRequired(for: $0.providerID) }
    }

    private func quotas() -> [UsageAdvisor.Quota] {
        enabledDescriptors().compactMap { descriptor in
            guard descriptor.limitResources.contains(where: { Self.quotaKeys.contains($0.key) }) else { return nil }
            let data = dataStore.data(for: descriptor)
            guard data.hasData, data.isBounded else { return nil }
            return UsageAdvisor.Quota(
                providerID: descriptor.providerID,
                family: ProviderAccountID.family(of: descriptor.providerID),
                providerName: displayName(descriptor.providerID),
                metricTitle: descriptor.title,
                data: data
            )
        }
    }

    private func resets(now: Date) -> [UsageAdvisor.ResetCredits] {
        let descriptors = enabledDescriptors()
        let spentCards = Set(descriptors.filter { descriptor in
            guard descriptor.limitResources.contains(where: { Self.claimableKeys.contains($0.key) }) else { return false }
            if case .spent = dataStore.data(for: descriptor).meterState(now: now) { return true }
            return false
        }.map(\.providerID))
        return descriptors.compactMap { descriptor in
            guard descriptor.sample.showsResetExpiries else { return nil }
            let data = dataStore.data(for: descriptor)
            guard data.hasData, let count = data.values.first?.number else { return nil }
            let spent = spentCards.contains(descriptor.providerID)
            return UsageAdvisor.ResetCredits(
                providerID: descriptor.providerID,
                family: ProviderAccountID.family(of: descriptor.providerID),
                providerName: displayName(descriptor.providerID),
                count: Int(count),
                expiries: data.expiriesAt,
                quotaSpent: spent
            )
        }
    }

    /// The selected team's plans that cover you, for providers this Mac uses: advice to use a plan
    /// you are not on, or a provider you don't have, helps nobody.
    private func teamPlans() -> [UsageAdvisor.Plan] {
        guard teams.isSignedIn, let teamID = teams.selectedTeamID,
              let report = plans.report(teamID: teamID) else { return [] }
        let families = Set(enabledDescriptors().map { ProviderAccountID.family(of: $0.providerID) })
        return Self.plansForYou(report, families: families).map { plan in
            UsageAdvisor.Plan(
                id: plan.id, family: plan.provider,
                providerName: registry.provider(id: plan.provider)?.displayName ?? plan.provider.capitalized,
                name: plan.name, projectedMultiple: plan.projectedMultiple, underused: plan.underused,
                daysLeft: plan.cycle.daysLeft + 1, cycleEnd: plan.cycle.to
            )
        }
    }

    static func plansForYou(_ report: TeamPlansReport, families: Set<String>) -> [TeamPlanReport] {
        report.plans.filter { $0.includesYou && families.contains($0.provider) }
    }
}
