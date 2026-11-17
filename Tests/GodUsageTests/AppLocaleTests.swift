import Foundation
import XCTest
@testable import GodUsage

/// `AppLocale`: the app's language picks the locale of every hand-formatted number, day and month,
/// while dollars stay American and the local API stays en_US.
final class AppLocaleTests: XCTestCase {
    private let italian = Locale(identifier: "it")
    private let english = AppLocale.stable

    // MARK: - Language

    func testLanguageIsTheFirstPreferredLocalizationElseEnglish() {
        XCTAssertEqual(AppLocale.languageCode(preferredLocalizations: ["it", "en"]), "it")
        XCTAssertEqual(AppLocale.languageCode(preferredLocalizations: ["en"]), "en")
        XCTAssertEqual(AppLocale.languageCode(preferredLocalizations: []), "en")
        XCTAssertEqual(AppLocale.languageCode(preferredLocalizations: ["Base"]), "en")
    }

    func testEnglishMapsToUSAndOtherLanguagesToThemselves() {
        XCTAssertEqual(AppLocale.locale(languageCode: "en").identifier, "en_US")
        XCTAssertEqual(AppLocale.locale(languageCode: "it").identifier, "it")
    }

    func testTestsRunInEnglishAndTheOverrideSwitchesTheLocale() {
        XCTAssertEqual(AppLocale.current.identifier, "en_US")
        AppLocale.$override.withValue(italian) {
            XCTAssertEqual(AppLocale.current.identifier, "it")
            XCTAssertEqual(LivePaceFormat.rate(10), "10,0%/h")
        }
        XCTAssertEqual(AppLocale.current.identifier, "en_US")
    }

    // MARK: - Numbers

    func testDecimalCommaInItalian() {
        XCTAssertEqual(AppLocale.percent(10, locale: italian), "10,0%")
        XCTAssertEqual(AppLocale.percent(10, locale: english), "10.0%")
        XCTAssertEqual(AppLocale.decimal(2.5, maxDigits: 1, locale: italian), "2,5")
        XCTAssertEqual(AppLocale.decimal(12, maxDigits: 1, locale: italian), "12")
        XCTAssertEqual(LivePaceFormat.rate(10, locale: italian), "10,0%/h")
        XCTAssertEqual(LivePaceFormat.percent(6.3, locale: italian), "6,3%")
        XCTAssertEqual(LivePaceFormat.percent(6.3, locale: english), "6.3%")
    }

    func testCompactKeepsTheLettersAndUsesTheLocaleSeparator() {
        XCTAssertEqual(AppLocale.compact(12_900, locale: italian), "12,9K")
        XCTAssertEqual(AppLocale.compact(12_900, locale: english), "12.9K")
        XCTAssertEqual(AppLocale.compact(3_400_000, locale: italian), "3,4M")
        XCTAssertEqual(AppLocale.compact(1_200_000_000, locale: english), "1.2B")
        XCTAssertEqual(AppLocale.compact(999_999, locale: english), "1M", "rounds up into the next unit")
        XCTAssertEqual(AppLocale.compact(820.6, locale: italian), "820,6")
    }

    func testOrdinals() {
        XCTAssertEqual(AppLocale.ordinal(1, locale: italian), "1º")
        XCTAssertEqual(AppLocale.ordinal(2, locale: italian), "2º")
        XCTAssertEqual(AppLocale.ordinal(1, locale: english), "1st")
        XCTAssertEqual(MemberDetailFormat.ordinal(3, locale: italian), "3º")
        XCTAssertEqual(MemberDetailFormat.ordinal(3, locale: english), "3rd")
    }

    func testDollarsStayAmericanInEveryLanguage() {
        AppLocale.$override.withValue(italian) {
            XCTAssertEqual(Formatters.currency(72.55), "$72.55")
            XCTAssertEqual(Formatters.currency(2059.07), "$2,059.07")
            XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .row), "$2.1K")
            // Counts follow the language; the local API passes the stable locale.
            XCTAssertEqual(MetricFormatter.number(12_900, kind: .count, style: .row), "12,9K")
            XCTAssertEqual(MetricFormatter.number(12_900, kind: .count, style: .row, countLocale: AppLocale.stable), "12.9K")
        }
    }

    // MARK: - Days and months

    /// Thursday 2026-11-05 … Monday 2026-11-09.
    func testItalianWeekdays() {
        XCTAssertEqual(LivePaceFormat.weekday("2026-11-04", locale: italian), "mer")
        XCTAssertEqual(LivePaceFormat.weekday("2026-11-05", locale: italian), "gio")
        XCTAssertEqual(LivePaceFormat.weekday("2026-11-05", locale: english), "Thu")
        XCTAssertEqual(LivePaceFormat.dayLabel("2026-11-06", today: "2026-11-05", locale: italian), "ven")
    }

    func testDayListsAndRangesUseTheLanguage() {
        XCTAssertEqual(LivePaceFormat.days(["2026-11-06", "2026-11-09"], locale: italian), "ven e lun")
        XCTAssertEqual(LivePaceFormat.days(["2026-11-06", "2026-11-09"], locale: english), "Fri and Mon")
        XCTAssertEqual(LivePaceFormat.dayRange(["2026-11-04", "2026-11-05", "2026-11-09"], locale: italian), "mer–lun")
        XCTAssertEqual(LivePaceFormat.dayRange(["2026-11-04", "2026-11-05", "2026-11-09"], locale: english), "Wed–Mon")
        XCTAssertEqual(LivePaceFormat.dayRange(["2026-11-04"], locale: italian), "mer")
    }

    func testItalianMonths() {
        XCTAssertEqual(TeamsFormat.monthName(11, locale: italian), "novembre")
        XCTAssertEqual(TeamsFormat.monthName(1, locale: italian), "gennaio")
        XCTAssertEqual(TeamsFormat.monthName(11, locale: english), "November")
    }

    /// "Oggi" for today comes from the catalog's Italian.
    func testTodayIsTranslatedInTheCatalog() throws {
        let url = try XCTUnwrap(Bundle.godUsageResources.url(forResource: "it", withExtension: "lproj"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.localizedString(forKey: "Today", value: nil, table: nil), "Oggi")
        XCTAssertEqual(bundle.localizedString(forKey: "On pace", value: nil, table: nil), "In linea")
    }
}
