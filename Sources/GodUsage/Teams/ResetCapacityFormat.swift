import Foundation

/// Words for a week with a claimed reset that kept its reset time (Claude): the week holds another
/// limit per claim, so it shows its use against its capacity ("95% + 40% of 200%"). Pure, so it is
/// unit-tested; the locale is a parameter for tests.
enum ResetCapacityFormat {
    /// The marker on a day a reset was claimed, and before the capacity line.
    static let mark = "↻"

    /// "95% + 40%" with each stretch's share when there are several, else the total "135%".
    static func used(_ used: Double, segments: [Double]?, locale: Locale = AppLocale.current) -> String {
        guard let segments, segments.count > 1 else { return short(used, locale) }
        return segments.map { short($0, locale) }.joined(separator: " + ")
    }

    /// The line under a plan's name in This Week's Limit: "↻ 95% + 40% of 200% this week".
    static func weekLine(_ week: TeamPlanBudget.WeekCapacity, locale: Locale = AppLocale.current) -> String {
        let used = used(week.usedPercent, segments: week.segments, locale: locale)
        let capacity = short(week.capacityPercent, locale)
        return String(localized: "\(mark) \(used) of \(capacity) this week", comment: "A week with a claimed limit reset: the use (each stretch between resets, added up), then the week's capacity, e.g. ↻ 95% + 40% of 200% this week")
    }

    /// "135% of 200%", or nil for a week without a claimed reset.
    static func usedOfCapacity(used: Double?, capacity: Double?, locale: Locale = AppLocale.current) -> String? {
        guard let used, let capacity, capacity > 100 else { return nil }
        return String(localized: "\(short(used, locale)) of \(short(capacity, locale))", comment: "A week's use against its capacity after a claimed limit reset, e.g. 135% of 200%")
    }

    /// "95%", "40.5%": whole points without a decimal, so the sum stays short.
    static func short(_ value: Double, _ locale: Locale) -> String {
        AppLocale.decimal(value, maxDigits: 1, locale: locale) + "%"
    }

    /// The Plans tab's note on quota used: "incl. 1 reset".
    static func quotaNote(resets: Int?) -> String? {
        guard let resets, resets > 0 else { return nil }
        return String(localized: "incl. \(resets) resets", comment: "Quota used counts windows with claimed limit resets against their larger capacity, e.g. incl. 1 reset")
    }
}
