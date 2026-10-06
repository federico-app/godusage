import UserNotifications
import XCTest
@testable import GodUsage

@MainActor
final class SetupPromptTests: XCTestCase {
    func testNotificationsDefaultOnForAFreshInstall() {
        let settings = NotificationSettingsStore(defaults: makeDefaults("fresh-notifications"))

        XCTAssertTrue(settings.underTenPercent)
        XCTAssertTrue(settings.healthyToClose)
        XCTAssertTrue(settings.closeToRunningOut)
        XCTAssertTrue(settings.resetExpiryReminders)
        XCTAssertTrue(settings.usageSuggestions)
        XCTAssertTrue(settings.teamOvertakes)
        XCTAssertTrue(settings.teamWeeklyRecap)
        XCTAssertTrue(settings.teamChallenges)
    }

    func testATriggerTurnedOffStaysOff() {
        let defaults = makeDefaults("off-stays-off")
        NotificationSettingsStore(defaults: defaults).teamOvertakes = false

        XCTAssertFalse(NotificationSettingsStore(defaults: defaults).teamOvertakes)
    }

    func testNotificationsCardComesBeforeLaunchAtLogin() {
        let onboarding = OnboardingStore(defaults: makeDefaults("order"))

        XCTAssertEqual(prompt(.notDetermined, onboarding: onboarding), .notifications)
        XCTAssertEqual(prompt(.authorized, onboarding: onboarding), .launchAtLogin)
        XCTAssertEqual(prompt(.denied, onboarding: onboarding), .launchAtLogin)
    }

    func testNoCardBeforeTheNotificationStatusIsKnown() {
        XCTAssertNil(prompt(nil, onboarding: OnboardingStore(defaults: makeDefaults("unknown"))))
    }

    func testNotificationsCardHidesWhenEveryAlertIsOff() {
        let onboarding = OnboardingStore(defaults: makeDefaults("all-off"))

        XCTAssertEqual(prompt(.notDetermined, anyEnabled: false, onboarding: onboarding), .launchAtLogin)
    }

    func testNoLoginCardWhenAlreadyLaunchingAtLogin() {
        let onboarding = OnboardingStore(defaults: makeDefaults("login-on"))

        XCTAssertNil(prompt(.authorized, launchAtLogin: true, onboarding: onboarding))
    }

    func testDismissedCardsStayDismissedAcrossInstances() {
        let defaults = makeDefaults("dismissed")
        let store = OnboardingStore(defaults: defaults)
        store.dismissNotificationsPrompt()
        store.dismissLaunchAtLoginPrompt()

        let reloaded = OnboardingStore(defaults: defaults)

        XCTAssertNil(prompt(.notDetermined, onboarding: reloaded))
    }

    private func prompt(
        _ status: UNAuthorizationStatus?, anyEnabled: Bool = true, launchAtLogin: Bool = false,
        onboarding: OnboardingStore
    ) -> SetupPrompt? {
        SetupPrompt.current(
            notificationStatus: status, anyNotificationEnabled: anyEnabled,
            launchAtLoginEnabled: launchAtLogin, onboarding: onboarding
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "SetupPromptTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
