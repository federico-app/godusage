import AppKit
import SwiftUI
import UserNotifications

/// A dashboard card that recommends one setup step at a time: first allowing notifications (every
/// alert defaults on, but macOS still needs permission), then Launch at Login. Each card leaves for
/// good when the user closes it, and stays hidden while the step is already done. A denied
/// notification permission is the user's answer, so the card does not nag about it.
struct SetupPromptCard: View {
    @Environment(AppContainer.self) private var container

    /// Nil until the first read, so the card doesn't flash before macOS answers.
    @State private var notificationStatus: UNAuthorizationStatus?

    /// Bottom gap below a visible card; the empty host takes no space.
    let bottomSpacing: CGFloat

    var body: some View {
        // A stack (not a Group) so the refresh task runs while no card is showing.
        VStack(spacing: 0) {
            switch SetupPrompt.current(
                notificationStatus: notificationStatus,
                anyNotificationEnabled: container.notificationSettings.anyEnabled,
                launchAtLoginEnabled: container.launchAtLogin.isEnabled,
                onboarding: container.onboarding
            ) {
            case .notifications:
                DismissableHintCard(
                    systemImage: "bell.badge",
                    title: "Enable Notifications",
                    message: "Get alerted before a quota runs out or an unused reset expires. Change which alerts you get in Settings.",
                    buttonTitle: "Allow Notifications",
                    action: allowNotifications,
                    onDismiss: { withAnimation(Motion.spring) { container.onboarding.dismissNotificationsPrompt() } }
                )
                .padding(.bottom, bottomSpacing)
                .transition(.scaleOrInstant(scale: 0.95))
            case .launchAtLogin:
                DismissableHintCard(
                    systemImage: "power",
                    title: "Launch at Login",
                    message: container.launchAtLogin.errorMessage
                        ?? "Start GodUsage with your Mac so usage and alerts stay up to date.",
                    buttonTitle: "Turn On",
                    action: { withAnimation(Motion.spring) { container.launchAtLogin.update(to: true) } },
                    onDismiss: { withAnimation(Motion.spring) { container.onboarding.dismissLaunchAtLoginPrompt() } }
                )
                .padding(.bottom, bottomSpacing)
                .transition(.scaleOrInstant(scale: 0.95))
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func allowNotifications() {
        Task {
            await AppNotifications.shared.requestAuthorization().value
            await refresh()
        }
    }

    private func refresh() async {
        container.launchAtLogin.refresh()
        let status = await AppNotifications.shared.authorizationStatus()
        withAnimation(Motion.spring) { notificationStatus = status }
    }
}

/// Which setup card the dashboard shows, if any. Pure so the ordering is testable.
enum SetupPrompt: Equatable {
    case notifications
    case launchAtLogin

    @MainActor
    static func current(
        notificationStatus: UNAuthorizationStatus?,
        anyNotificationEnabled: Bool,
        launchAtLoginEnabled: Bool,
        onboarding: OnboardingStore
    ) -> SetupPrompt? {
        if notificationStatus == .notDetermined, anyNotificationEnabled, !onboarding.isNotificationsPromptDismissed {
            return .notifications
        }
        // Wait for the notification status so the login card never shows a frame before it.
        if notificationStatus != nil, !launchAtLoginEnabled, !onboarding.isLaunchAtLoginPromptDismissed {
            return .launchAtLogin
        }
        return nil
    }
}
