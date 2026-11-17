import Foundation

/// The app's language as a `Locale`, for every number, date and list the UI formats by hand.
///
/// The app's language is the first of the main bundle's preferred localizations (Italian when the Mac
/// or the app is set to Italian, else English), not the Mac's region: an English app on an Italian Mac
/// still reads "Wed" and "10.0%", an Italian one "mer" and "10,0%". Output other programs read (the
/// local HTTP API, the CLI) uses `stable` instead, so it never changes with the language.
///
/// Dollar amounts are the exception: they stay American in every language ("$72.55", `Formatters.currency`),
/// an owner decision, since every amount is in US dollars.
enum AppLocale {
    /// en_US, for machine-readable output that must not change with the app's language.
    static let stable = Locale(identifier: "en_US")

    /// The language the app resolved at launch ("en", "it"). It can't change while the app runs.
    static let languageCode = languageCode(preferredLocalizations: Bundle.main.preferredLocalizations)

    /// Overrides `current` inside `AppLocale.$override.withValue(…)`, for tests and offscreen renders.
    @TaskLocal static var override: Locale?

    /// The locale of the app's language: en_US for English, the bare language otherwise.
    static var current: Locale { override ?? resolved }

    private static let resolved = locale(languageCode: languageCode)

    /// The first preferred localization, "en" when there is none (a bare `swift run` or `swift test`).
    static func languageCode(preferredLocalizations: [String]) -> String {
        guard let first = preferredLocalizations.first, !first.isEmpty, first != "Base" else { return "en" }
        return first
    }

    static func locale(languageCode: String) -> Locale {
        languageCode == "en" ? stable : Locale(identifier: languageCode)
    }

    // MARK: - Numbers

    /// A plain decimal with exactly `digits` fraction digits: "10.0" / "10,0".
    static func decimal(_ value: Double, digits: Int = 1, locale: Locale = current) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    /// A decimal with up to `maxDigits` fraction digits: "12" / "12.5" / "12,5".
    static func decimal(_ value: Double, maxDigits: Int, locale: Locale = current) -> String {
        value.formatted(.number.precision(.fractionLength(0...maxDigits)).grouping(.never).locale(locale))
    }

    /// Percentage points with one decimal: "10.0%" / "10,0%".
    static func percent(_ value: Double, digits: Int = 1, locale: Locale = current) -> String {
        decimal(value, digits: digits, locale: locale) + "%"
    }

    /// A short count with a K/M/B suffix and the locale's decimal separator: "12.9K" / "12,9K". The
    /// letters stay the same in every language: the localized names ("Mln", "Mld") don't fit the
    /// strip and the pills.
    static func compact(_ value: Double, maxDigits: Int = 1, locale: Locale = current) -> String {
        let magnitude = abs(value)
        let (scaled, suffix): (Double, String) = switch magnitude {
        case 999_950_000...: (value / 1e9, "B")
        case 999_950...: (value / 1e6, "M")
        case 999.95...: (value / 1e3, "K")
        default: (value, "")
        }
        return decimal(scaled, maxDigits: maxDigits, locale: locale) + suffix
    }

    /// "1st" / "1º".
    static func ordinal(_ value: Int, locale: Locale = current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "#\(value)"
    }

    /// "Fri, Mon, and Wed" / "ven, lun e mer".
    static func list(_ items: [String], locale: Locale = current) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}
