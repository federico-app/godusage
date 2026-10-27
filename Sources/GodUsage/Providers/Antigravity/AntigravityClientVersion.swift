import AppKit
import Foundation

/// The Antigravity app version GodUsage reports in its Antigravity-shaped User-Agent.
///
/// Cloud Code's `loadCodeAssist` only returns the user's tier to callers that look like the
/// Antigravity client (`antigravity/<version> (aidev_client; …)`). The installed app's
/// `CFBundleShortVersionString` keeps that version current; when the app isn't installed (`agy`-only
/// setups) or its Info.plist is unreadable, the pinned fallback is used instead.
enum AntigravityClientVersion {
    static let bundleIdentifier = "com.google.antigravity"
    /// Last Antigravity release this request shape was verified against (matches upstream OpenUsage).
    static let fallback = "2.24.0"

    /// The installed Antigravity version, or nil when the app can't be found or reports an unusable
    /// version. Reads the Info.plist directly (not `Bundle(url:)`, which caches the dictionary for the
    /// process lifetime) so an Antigravity update is picked up on the next refresh.
    @Sendable
    static func installed() -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            AppLog.debug(LogTag.plugin("antigravity"), "Antigravity app not found; using client version \(fallback)")
            return nil
        }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: plistURL)
        guard let version = sanitized(info?["CFBundleShortVersionString"] as? String) else {
            AppLog.warn(LogTag.plugin("antigravity"), "Antigravity Info.plist has no usable version; using client version \(fallback)")
            return nil
        }
        return version
    }

    /// Accepts only a plain dotted version (`2.23.1`), so a malformed plist value can't inject
    /// anything into the User-Agent header.
    static func sanitized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              value.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    /// Antigravity's own User-Agent shape (`%s/%s (aidev_client; os_type=…; arch=…)` in its
    /// language server). Google marks other callers `UNSUPPORTED_CLIENT` and drops `paidTier`.
    static func userAgent(version: String?) -> String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/\(sanitized(version) ?? fallback) (aidev_client; os_type=darwin; arch=\(arch))"
    }
}
