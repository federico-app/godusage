import Foundation
import Observation

/// User preferences for quota pace and reset-credit expiry notifications. All default OFF;
/// the app requests authorization the first time a trigger is turned on.
///
/// Persisted in `UserDefaults` (each key independently, with an unset key defaulting to `false`).
/// `@Observable` lets the Settings toggles and `WidgetDataStore` evaluation read live values.
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults

    private static let underTenKey = "godusage.notifications.underTenPercent"
    private static let healthyToCloseKey = "godusage.notifications.healthyToClose"
    private static let closeToRunningOutKey = "godusage.notifications.closeToRunningOut"
    private static let resetExpiryKey = "godusage.notifications.resetExpiryReminders"
    private static let teamOvertakesKey = "godusage.notifications.teamOvertakes"
    private static let teamWeeklyRecapKey = "godusage.notifications.teamWeeklyRecap"
    private static let teamChallengesKey = "godusage.notifications.teamChallenges"

    /// Announce the winners when a team challenge ends.
    var teamChallenges: Bool {
        didSet { defaults.set(teamChallenges, forKey: Self.teamChallengesKey) }
    }

    /// Alert when a teammate passes you by spend over the last 7 days.
    var teamOvertakes: Bool {
        didSet { defaults.set(teamOvertakes, forKey: Self.teamOvertakesKey) }
    }

    /// A Monday summary of last week in each of your teams.
    var teamWeeklyRecap: Bool {
        didSet { defaults.set(teamWeeklyRecap, forKey: Self.teamWeeklyRecapKey) }
    }

    var resetExpiryReminders: Bool {
        didSet { defaults.set(resetExpiryReminders, forKey: Self.resetExpiryKey) }
    }

    /// Transient delivery/storage failure, shown in Settings alongside the permission controls.
    var resetReminderError: String?

    /// Alert the first time a metric drops under 10% remaining for the period.
    var underTenPercent: Bool {
        didSet { defaults.set(underTenPercent, forKey: Self.underTenKey) }
    }

    /// Alert when pace worsens from healthy (blue) to close-to-limit (yellow).
    var healthyToClose: Bool {
        didSet { defaults.set(healthyToClose, forKey: Self.healthyToCloseKey) }
    }

    /// Alert when pace worsens from close-to-limit (yellow) to running-out (red).
    var closeToRunningOut: Bool {
        didSet { defaults.set(closeToRunningOut, forKey: Self.closeToRunningOutKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.underTenPercent = defaults.bool(forKey: Self.underTenKey, default: false)
        self.healthyToClose = defaults.bool(forKey: Self.healthyToCloseKey, default: false)
        self.closeToRunningOut = defaults.bool(forKey: Self.closeToRunningOutKey, default: false)
        self.resetExpiryReminders = defaults.bool(forKey: Self.resetExpiryKey, default: false)
        self.teamOvertakes = defaults.bool(forKey: Self.teamOvertakesKey, default: false)
        self.teamWeeklyRecap = defaults.bool(forKey: Self.teamWeeklyRecapKey, default: false)
        self.teamChallenges = defaults.bool(forKey: Self.teamChallengesKey, default: false)
    }

    /// The per-milestone toggles as the pure logic consumes them.
    var toggles: PaceNotificationToggles {
        PaceNotificationToggles(
            underTenPercent: underTenPercent,
            healthyToClose: healthyToClose,
            closeToRunningOut: closeToRunningOut
        )
    }

    /// True when at least one trigger is on — used to decide whether to request authorization (when the
    /// first trigger is turned on) and whether the Settings permission notice should show. Turning all
    /// triggers off silences everything.
    var anyEnabled: Bool {
        underTenPercent || healthyToClose || closeToRunningOut || resetExpiryReminders || teamOvertakes || teamWeeklyRecap
            || teamChallenges
    }
}
