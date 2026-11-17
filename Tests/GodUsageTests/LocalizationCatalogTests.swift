import Foundation
import XCTest
@testable import GodUsage

/// Guards the String Catalog (`Sources/GodUsage/Resources/Localizable.xcstrings`): a key added by
/// `script/sync_localizations.sh` without an Italian translation fails CI here instead of shipping
/// as English in the Italian app.
final class LocalizationCatalogTests: XCTestCase {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GodUsageTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources/GodUsage/Resources/Localizable.xcstrings")

    private struct Entry {
        let key: String
        let json: [String: Any]
        var shouldTranslate: Bool { json["shouldTranslate"] as? Bool ?? true }
        var isStale: Bool { json["extractionState"] as? String == "stale" }
        func localization(_ language: String) -> [String: Any]? {
            (json["localizations"] as? [String: Any])?[language] as? [String: Any]
        }
    }

    private func loadEntries() throws -> [Entry] {
        let data = try Data(contentsOf: Self.catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        return strings.map { Entry(key: $0.key, json: $0.value) }.sorted { $0.key < $1.key }
    }

    /// Every value of a localization: the plain string unit, or each plural/device variation.
    private func values(of localization: [String: Any]) -> [String] {
        var result: [String] = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            result.append(unit["value"] as? String ?? "")
        }
        if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
            for cases in variations.values {
                for variant in cases.values {
                    result += values(of: variant)
                }
            }
        }
        return result
    }

    func testEveryKeyHasAnItalianTranslation() throws {
        let entries = try loadEntries()
        XCTAssertFalse(entries.isEmpty)
        var missing: [String] = []
        for entry in entries where entry.shouldTranslate && !entry.isStale && !entry.key.isEmpty {
            let italian = entry.localization("it").map(values(of:)) ?? []
            if italian.isEmpty || italian.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                missing.append(entry.key)
            }
        }
        XCTAssertTrue(missing.isEmpty, "Keys without an Italian translation:\n" + missing.joined(separator: "\n"))
    }

    /// An Italian string must consume the same format arguments as the key, or `String(format:)`
    /// reads the wrong argument (or crashes) at runtime.
    func testItalianFormatSpecifiersMatchTheKey() throws {
        var mismatched: [String] = []
        for entry in try loadEntries() where entry.shouldTranslate && !entry.isStale {
            guard let italian = entry.localization("it") else { continue }
            let expected = Self.specifiers(in: entry.key)
            let expectedTotal = expected.values.reduce(0, +)
            for value in values(of: italian) {
                let actual = Self.specifiers(in: value)
                let substitutions = actual["#@", default: 0]
                let typed = actual.filter { $0.key != "#@" }
                let total = typed.values.reduce(0, +) + substitutions
                // Every typed argument must exist in the key; a plural substitution (%#@n@) stands for
                // one of them, and a plural "one" form may spell the number out ("used once").
                let fits = typed.allSatisfy { expected[$0.key, default: 0] >= $0.value } && total <= expectedTotal
                let complete = total == expectedTotal || (entry.localization("it")?["variations"] != nil)
                if !fits || !complete {
                    mismatched.append("\(entry.key) -> \(value)")
                }
            }
        }
        XCTAssertTrue(mismatched.isEmpty, "Format specifiers differ:\n" + mismatched.joined(separator: "\n"))
    }

    /// Provider metric titles are translated at display time (`LocalizedMetricTitle`), so the catalog
    /// lists them by hand. A new descriptor title without an entry would stay English.
    @MainActor
    func testEveryMetricTitleHasACatalogEntry() throws {
        let keys = Set(try loadEntries().map(\.key))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalizationCatalogTests.\(UUID().uuidString)"))
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: defaults))
        let titles = Set(registry.providers.flatMap { registry.descriptors(for: $0.id) }.map(\.sample.title))
        XCTAssertFalse(titles.isEmpty)
        let missing = titles.subtracting(keys).sorted()
        XCTAssertTrue(missing.isEmpty, "Metric titles missing from Localizable.xcstrings: \(missing)")
    }

    /// The compiled catalog in the resource bundle resolves Italian, including plural variations.
    func testCompiledCatalogResolvesItalian() throws {
        let resources = Bundle.godUsageResources
        let italianURL = try XCTUnwrap(resources.url(forResource: "it", withExtension: "lproj"),
                                       "it.lproj missing from \(resources.bundlePath)")
        let italian = try XCTUnwrap(Bundle(url: italianURL))
        XCTAssertEqual(italian.localizedString(forKey: "Cancel", value: nil, table: nil), "Annulla")
        XCTAssertEqual(LocalizedMetricTitle.string("Weekly", bundle: italian), "Settimanale")
        XCTAssertEqual(LocalizedMetricTitle.string("No Such Title", bundle: italian), "No Such Title")
        let days = italian.localizedString(forKey: "%lld days", value: nil, table: nil)
        XCTAssertEqual(String.localizedStringWithFormat(days, 1), "1 giorno")
        XCTAssertEqual(String.localizedStringWithFormat(days, 3), "3 giorni")
    }

    /// `%@`, `%lld`, `%1$@`, … counted by argument type, so "%1$@ di %2$@" equals "%@ of %@".
    /// A plural substitution (`%1$#@name@`) counts as "#@".
    private static func specifiers(in string: String) -> [String: Int] {
        let pattern = #"%(\d+\$)?(#@|lld|ld|d|@|f|\.\d+f)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(string.startIndex..., in: string)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: string, range: range) {
            guard let typeRange = Range(match.range(at: 2), in: string) else { continue }
            counts[String(string[typeRange]), default: 0] += 1
        }
        return counts
    }
}
