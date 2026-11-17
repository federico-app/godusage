import Foundation

/// How a piece of menu-bar text is drawn. `primary` and `dim` follow the menu bar's own text color;
/// `warning` (orange) and `positive` (green) are the only colors the strip uses. `chip` is a solid
/// orange capsule with dark text.
enum MenuBarTone: Equatable {
    case primary
    case dim
    case warning
    case positive
    case chip

    /// Needs a colored (non-template) image.
    var isColored: Bool { [.warning, .positive, .chip].contains(self) }
}

/// One run of text on a menu-bar line, e.g. "91%·3d" in orange or "▲1" in green.
struct MenuBarSpan: Equatable {
    let text: String
    let tone: MenuBarTone

    init(_ text: String, _ tone: MenuBarTone = .primary) {
        self.text = text
        self.tone = tone
    }
}

/// The small dot on a provider icon.
enum MenuBarBadge: Equatable {
    /// Green: the account the "Switch to …" suggestion recommends.
    case useNow
    /// Orange: the login needs renewing.
    case loginRenewal

    /// A login that needs renewing outranks the suggestion: the account can't be used until then.
    static func decide(loginRequired: Bool, isSwitchTarget: Bool) -> MenuBarBadge? {
        if loginRequired { return .loginRenewal }
        return isSwitchTarget ? .useNow : nil
    }
}

/// The dimmed one-letter prefix in front of a stacked value, for the session (five-hour) window and
/// the weekly one. Derived from the metric's exported limit key, never from its position, so a
/// provider that stars Weekly alone still reads as weekly.
enum MenuBarMetricLabel {
    static let sessionKeys: Set<String> = ["session", "geminiSession"]
    static let weeklyKeys: Set<String> = ["weekly", "geminiWeekly"]

    enum Window: Equatable {
        case session
        case weekly

        /// "S"/"W" in English. Italian can't use the initials, since Sessione and Settimanale both
        /// start with S: it reads "H" (the hours window) and "S" (settimanale).
        var letter: String {
            switch self {
            case .session: String(localized: "S", comment: "Menu bar: one-letter prefix of the session (five-hour) window value. Must differ from the weekly letter.")
            case .weekly: String(localized: "W", comment: "Menu bar: one-letter prefix of the weekly window value. Must differ from the session letter.")
            }
        }
    }

    static func window(for descriptor: WidgetDescriptor) -> Window? {
        window(limitKeys: descriptor.limitResources.map(\.key))
    }

    /// Only the provider's main session and weekly windows get a letter. Model pools that have their
    /// own windows (Antigravity's Claude pool, Codex Spark) and every other metric get none.
    static func window(limitKeys: [String]) -> Window? {
        if limitKeys.contains(where: sessionKeys.contains) { return .session }
        if limitKeys.contains(where: weeklyKeys.contains) { return .weekly }
        return nil
    }

    /// The letter drawn in front of the value, in the app's language.
    static func prefix(for descriptor: WidgetDescriptor) -> String? {
        window(for: descriptor)?.letter
    }
}

/// What a starred value reads in the Text strip, in order of precedence:
///
/// 1. A session window with under 10% left: the value and the time until it resets, in orange
///    ("8% ↻38m"), so the strip still says where the session stands.
/// 2. A used-up limit: the time until it resets, dimmed ("↻2d 4h").
/// 3. Over pace (the dashboard's flame): the value in orange plus the time to the projected limit
///    ("91%·3d"), or the value alone in orange when it lands right at the limit.
/// 4. Otherwise the plain value.
enum MenuBarValueText {
    static let sessionCountdownThreshold = 0.10

    static func spans(value: String, window: MenuBarMetricLabel.Window?, data: WidgetData, now: Date) -> [MenuBarSpan] {
        guard data.hasData, let limit = data.limit, limit > 0 else { return [MenuBarSpan(value)] }
        let untilReset = data.resetsAt.map { $0.timeIntervalSince(now) }
        if window == .session, data.remainingFraction < sessionCountdownThreshold,
           let untilReset, let reset = resetText(untilReset) {
            return [MenuBarSpan("\(value) \(reset)", .warning)]
        }
        let state = data.meterState(now: now)
        switch state {
        case .spent:
            if let untilReset, let reset = resetText(untilReset) { return [MenuBarSpan(reset, .dim)] }
            return [MenuBarSpan(value, .warning)]
        case .runningOut:
            if let seconds = secondsToLimit(data, now: now), let eta = limitETA(seconds) {
                return [MenuBarSpan("\(value)·\(eta)", .warning)]
            }
            return [MenuBarSpan(value, .warning)]
        default:
            return [MenuBarSpan(value)]
        }
    }

    /// The dashboard's "Limit in 3d 17h" projection, in seconds. Nil when the pace doesn't run out
    /// before the reset.
    static func secondsToLimit(_ data: WidgetData, now: Date) -> TimeInterval? {
        guard data.hasData, let limit = data.limit, limit > 0, let resetsAt = data.resetsAt,
              let periodMs = data.periodDurationMs, periodMs > 0 else { return nil }
        return Pace.secondsToRunOut(
            used: data.used, limit: limit, resetsAt: resetsAt,
            periodDuration: TimeInterval(periodMs) / 1000, now: now
        )
    }

    /// The largest whole unit only: "3d", "17h", "45m".
    static func limitETA(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded(.down)))
        if minutes >= 24 * 60 {
            let days = minutes / (24 * 60)
            return String(localized: "\(days)d", comment: "Compact duration: days")
        }
        if minutes >= 60 {
            let hours = minutes / 60
            return String(localized: "\(hours)h", comment: "Compact duration: hours")
        }
        return String(localized: "\(minutes)m", comment: "Compact duration: minutes")
    }

    /// "↻38m", "↻4h 10m", "↻2d 4h"; nil once the reset has passed.
    static func resetText(_ seconds: TimeInterval) -> String? {
        Formatters.compactDuration(seconds).map { "↻\($0)" }
    }
}
