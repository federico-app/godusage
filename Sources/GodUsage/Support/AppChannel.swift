import SwiftUI

/// Which release channel this build is: production or GodUsage DEV (bundle id ending in `.dev`).
enum AppChannel {
    static func isDev(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier?.hasSuffix(".dev") == true
    }

    /// The URL scheme the app registers (`CFBundleURLTypes`, written by `script/release.sh`): each
    /// channel its own, so a link meant for the DEV app never opens the release app, or the reverse.
    static func urlScheme(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        isDev(bundleIdentifier: bundleIdentifier) ? "godusage-dev" : "godusage"
    }
}

/// "DEV" capsule at the top of the dashboard, so a GodUsage DEV popover is never mistaken for the
/// production app. Shown only in DEV builds.
struct DevBuildBadge: View {
    var body: some View {
        if AppChannel.isDev() {
            Text("DEV")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.orange, in: Capsule())
                .accessibilityLabel("GodUsage DEV build")
        }
    }
}
