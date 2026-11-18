import Foundation

/// The text of a linked device's row in Settings: "iPhone 13 · iOS 26.1" as the title, and
/// "Linked on Nov 18 · Last active 5m ago · GodUsage 1.10.1" under it. Pieces the device never
/// reported are left out.
enum LinkedDeviceFormat {
    /// The model and OS when the phone reported them, else the name it linked with.
    static func title(_ device: LinkedDevice) -> String {
        guard let model = device.model else { return device.name }
        guard let os = device.osVersion else { return model }
        let system = model.hasPrefix("iPad") ? "iPadOS" : "iOS"
        return "\(model) · \(system) \(os)"
    }

    static func subtitle(_ device: LinkedDevice, now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let linked = date(device.linkedAt) {
            let sameYear = calendar.component(.year, from: linked) == calendar.component(.year, from: now)
            let label = sameYear
                ? Formatters.monthDayLabel(linked)
                : linked.formatted(.dateTime.year().month(.abbreviated).day().locale(AppLocale.current))
            parts.append(String(localized: "Linked on \(label)", comment: "When a phone or iPad was linked; the argument is a short date, e.g. Nov 18"))
        }
        if let seen = device.lastSeenAt.flatMap(date) {
            parts.append(lastActive(seen, now: now))
        }
        if let version = device.appVersion {
            parts.append("GodUsage \(version)")
        }
        return parts.joined(separator: " · ")
    }

    /// "Last active just now", "… 5m ago", "… 3h ago", "… 2d ago". The server records it at most
    /// once an hour, so it is never more precise than that for a phone in use.
    static func lastActive(_ seen: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(seen)) / 60)
        let hours = minutes / 60, days = minutes / (24 * 60)
        if minutes < 1 { return String(localized: "Last active just now") }
        if minutes < 60 { return String(localized: "Last active \(minutes)m ago", comment: "Minutes since a linked phone last used GodUsage.") }
        if hours < 24 { return String(localized: "Last active \(hours)h ago", comment: "Hours since a linked phone last used GodUsage.") }
        return String(localized: "Last active \(days)d ago", comment: "Days since a linked phone last used GodUsage.")
    }

    static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }
}
