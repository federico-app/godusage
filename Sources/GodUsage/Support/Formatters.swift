import Foundation
import os

/// Shared display formatters for live usage data: the mode-aware deadline/reset phrasing
/// (`deadlineLabel`, `resetRelativeLabel`, `resetAbsoluteLabel`), compact durations, and USD currency.
enum Formatters {
    /// Configured formatters by fraction digits. `NumberFormatter` construction costs tens of
    /// microseconds and this runs inside SwiftUI `body` for every dollar value on screen, so the
    /// instances are built once. Formatting happens inside the lock — `NumberFormatter` is not
    /// documented thread-safe, and off-main callers (the one-shot CLI, share renders) exist.
    private static let currencyFormatters = OSAllocatedUnfairLock<[Int: NumberFormatter]>(initialState: [:])

    static func currency(_ amount: Double, fractionDigits: Int = 2) -> String {
        let formatted = currencyFormatters.withLock { cache -> String? in
            let formatter: NumberFormatter
            if let cached = cache[fractionDigits] {
                formatter = cached
            } else {
                let f = NumberFormatter()
                f.numberStyle = .currency
                f.currencyCode = "USD"
                f.locale = Locale(identifier: "en_US")
                f.maximumFractionDigits = fractionDigits
                f.minimumFractionDigits = fractionDigits
                cache[fractionDigits] = f
                formatter = f
            }
            return formatter.string(from: amount as NSNumber)
        }
        // The fallback must also respect the requested precision: a raw "$\(amount)" would leak the
        // double's full decimals (e.g. "$180.168"), which is exactly the rounding glitch we're fixing.
        return formatted ?? "$\(String(format: "%.\(fractionDigits)f", amount))"
    }

    /// The app's compact month/day, e.g. "Jun 21" — localized, no year. Shared so every short calendar
    /// date (reset deadlines, the Usage Trend axis) reads the same and changes in one place.
    static func monthDayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The one mode-aware deadline phrase, shared by every "<verb> + when" label (reset countdowns,
    /// run-out projections): `.relative` → "<prefix> in 2d 6h", `.absolute` → "<prefix> today at
    /// 5:30 PM" / "<prefix> tomorrow at 9:00 AM" / "<prefix> Feb 15 at 3:45 PM" (ported from the
    /// original's `formatResetAbsoluteLabel`; time uses the locale's 12/24-hour convention). An
    /// imminent deadline (≤5 min out relative, past-due absolute) collapses to "<prefix> soon".
    static func deadlineLabel(
        _ prefix: String,
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let when = whenLabel(at: date, mode: mode, now: now, calendar: calendar) else { return nil }
        return deadlinePhrase(prefix, when: when, isImminent: when == imminent, relative: mode == .relative)
    }

    /// One full localizable sentence per known verb, so a translation can reorder words instead of
    /// gluing "<verb> in <when>" fragments. The verbs stay English at the call sites (`prefix`); an
    /// unknown one falls back to a generic "<verb> in <when>" template.
    private static func deadlinePhrase(_ prefix: String, when: String, isImminent: Bool, relative: Bool) -> String {
        switch prefix {
        case "Resets":
            if isImminent { return String(localized: "Resets soon", comment: "A usage limit resets within minutes") }
            return relative
                ? String(localized: "Resets in \(when)", comment: "A usage limit resets after a duration, e.g. in 2d 6h")
                : String(localized: "Resets \(when)", comment: "A usage limit resets at a time, e.g. today at 5:30 PM")
        case "Reset expires":
            if isImminent { return String(localized: "Reset expires soon", comment: "An unused reset credit expires within minutes") }
            return relative
                ? String(localized: "Reset expires in \(when)", comment: "An unused reset credit expires after a duration")
                : String(localized: "Reset expires \(when)", comment: "An unused reset credit expires at a time, e.g. today at 5:30 PM")
        case "Limit":
            if isImminent { return String(localized: "Limit soon", comment: "Usage is projected to hit the limit within minutes") }
            return relative
                ? String(localized: "Limit in \(when)", comment: "Usage is projected to hit the limit after a duration")
                : String(localized: "Limit \(when)", comment: "Usage is projected to hit the limit at a time, e.g. today at 5:30 PM")
        default:
            if isImminent { return String(localized: "\(prefix) soon", comment: "Generic deadline: <verb> soon") }
            return relative
                ? String(localized: "\(prefix) in \(when)", comment: "Generic deadline: <verb> in <duration>")
                : "\(prefix) \(when)"
        }
    }

    /// The verb-less "when" phrase shared by `deadlineLabel` (which prefixes a verb) and the
    /// reset-credit tooltip (which lists bare entries): `.relative` → "2d 6h" / `imminent`;
    /// `.absolute` → "today at 5:30 PM" / "tomorrow at 9:00 AM" / "Feb 15 at 3:45 PM" / `imminent`
    /// (past-due or ≤5 min out). `nil` only when the duration is non-finite.
    static func whenLabel(
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch mode {
        case .relative:
            let seconds = date.timeIntervalSince(now)
            if seconds <= 5 * 60 { return imminent }
            return compactDuration(seconds)
        case .absolute:
            guard date.timeIntervalSince(now) > 0 else { return imminent }
            let dayDiff = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
            // The wall-clock part honors the user's Auto/12h/24h time-format setting.
            let time = TimeFormatSetting.current.shortTime(date)
            if dayDiff <= 0 { return String(localized: "today at \(time)", comment: "Deadline time later today") }
            if dayDiff == 1 { return String(localized: "tomorrow at \(time)", comment: "Deadline time tomorrow") }
            return String(localized: "\(monthDayLabel(date)) at \(time)", comment: "Deadline: <month day> at <time>, e.g. Feb 15 at 3:45 PM")
        }
    }

    /// The collapsed phrase for a deadline that's past-due or within ~5 minutes — too close to print a
    /// useful countdown. Shared so `deadlineLabel` and any bare-`whenLabel` caller agree on the wording.
    static var imminent: String { String(localized: "soon", comment: "A deadline only minutes away") }

    static func resetRelativeLabel(until resetsAt: Date, now: Date = Date()) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .relative, now: now)
    }

    static func resetAbsoluteLabel(at resetsAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .absolute, now: now, calendar: calendar)
    }

    /// Compact "Xd Yh" / "Xh Ym" / "Xm" duration. At the day scale it always shows two units — the
    /// hours ride along even when zero ("4d 0h") — so a span 4 days + 52 min out never reads as a flat
    /// "4d" that hides the sub-day remainder. Minutes are dropped at the day scale.
    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return String(localized: "\(days)d \(hours)h", comment: "Compact duration: days and hours")
        }
        if hours > 0 {
            return minutes > 0
                ? String(localized: "\(hours)h \(minutes)m", comment: "Compact duration: hours and minutes")
                : String(localized: "\(hours)h", comment: "Compact duration: hours")
        }
        return String(localized: "\(minutes)m", comment: "Compact duration: minutes")
    }
}
