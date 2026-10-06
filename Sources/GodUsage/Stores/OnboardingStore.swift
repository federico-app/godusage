import Foundation
import Observation

/// One-time onboarding state: whether the dashboard should still show the first-run Customize hint
/// card, and whether the user closed the Enable Notifications or Launch at Login setup cards.
/// `FirstRunSeeder` marks the Customize hint pending when it seeds a fresh install's provider set
/// (existing installs are never seeded, so they never see that card); it clears when the user
/// dismisses it. The setup cards show to every install until closed or acted on.
@MainActor
@Observable
final class OnboardingStore {
    private static let customizeHintPendingKey = "godusage.onboarding.customizeHintPending"
    private static let notificationsPromptDismissedKey = "godusage.onboarding.notificationsPromptDismissed"
    private static let launchAtLoginPromptDismissedKey = "godusage.onboarding.launchAtLoginPromptDismissed"

    private(set) var isCustomizeHintPending: Bool
    private(set) var isNotificationsPromptDismissed: Bool
    private(set) var isLaunchAtLoginPromptDismissed: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCustomizeHintPending = defaults.bool(forKey: Self.customizeHintPendingKey)
        self.isNotificationsPromptDismissed = defaults.bool(forKey: Self.notificationsPromptDismissedKey)
        self.isLaunchAtLoginPromptDismissed = defaults.bool(forKey: Self.launchAtLoginPromptDismissedKey)
    }

    func markCustomizeHintPending() {
        guard !isCustomizeHintPending else { return }
        isCustomizeHintPending = true
        defaults.set(true, forKey: Self.customizeHintPendingKey)
    }

    func dismissCustomizeHint() {
        guard isCustomizeHintPending else { return }
        isCustomizeHintPending = false
        defaults.set(false, forKey: Self.customizeHintPendingKey)
    }

    func dismissNotificationsPrompt() {
        guard !isNotificationsPromptDismissed else { return }
        isNotificationsPromptDismissed = true
        defaults.set(true, forKey: Self.notificationsPromptDismissedKey)
    }

    func dismissLaunchAtLoginPrompt() {
        guard !isLaunchAtLoginPromptDismissed else { return }
        isLaunchAtLoginPromptDismissed = true
        defaults.set(true, forKey: Self.launchAtLoginPromptDismissedKey)
    }
}
