import Foundation

/// Display formatting for team numbers, names, and dates.
///
/// Numbers follow the app's language, like the Mac (see `docs/localization.md`): "6.3%" in English,
/// "6,3%" in Italian, with K/M/B kept in every language. Dollars stay American everywhere ("$72.55").
/// Dates use the app's language with the device's region, so clock times keep its 12- or 24-hour style.
enum TeamsFormat {
    /// The language the app resolved at launch ("en", "it").
    static let languageCode: String = {
        guard let first = Bundle.main.preferredLocalizations.first, !first.isEmpty, first != "Base" else { return "en" }
        return first
    }()

    /// en_US for English, the bare language otherwise.
    static let numberLocale = languageCode == "en" ? Locale(identifier: "en_US") : Locale(identifier: languageCode)

    /// The app's language with the device's region and clock preferences.
    static let dateLocale: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: languageCode)
        return Locale(components: components)
    }()

    private static let dollars = Locale(identifier: "en_US")

    static func cost(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(value >= 1_000 ? 0 : 2)).locale(dollars))
    }

    /// Counts below a million print in full with thousands separators ("58,342" / "58.342"); larger
    /// ones stay compact ("1.2M" / "1,2M", "3.4B") so rows don't overflow.
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch abs(number) {
        case 1_000_000_000...: return decimal(number / 1_000_000_000) + "B"
        case 1_000_000...: return decimal(number / 1_000_000) + "M"
        default: return value.formatted(.number.locale(numberLocale))
        }
    }

    /// "62%", "62.5%" / "62,5%": up to one decimal.
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(numberLocale)) + "%"
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(numberLocale))
    }

    /// Provider ids as the Mac shows them, for the common ones; others are capitalized.
    static func providerName(_ id: String) -> String {
        let known = ["claude": "Claude", "codex": "Codex", "cursor": "Cursor", "grok": "Grok", "devin": "Devin", "copilot": "Copilot", "gemini": "Gemini", "opencode": "OpenCode"]
        return known[id] ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The viewer's local calendar day, as the server's `today` parameter.
    static func localToday(_ date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A server timestamp ("2026-11-18T09:30:00.000Z", with or without fractional seconds).
    static func instant(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        if let date = try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(iso, strategy: Date.ISO8601FormatStyle())
    }

    /// A server day ("2026-11-18") at noon in the device's time zone, for charts.
    static func day(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func syncAge(_ iso: String?) -> String? {
        guard let date = instant(iso) else { return nil }
        let age = date.formatted(.relative(presentation: .named).locale(dateLocale))
        return String(localized: "Updated \(age)", comment: "When a member's Macs last shared usage, e.g. Updated 5 minutes ago")
    }

    /// When a weekly limit resets: "Wed 10:00" / "mer 10:00".
    static func weekdayTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(dateLocale))
    }
}
