import Foundation

/// Display-edge translation for provider metric titles ("Session", "Weekly", "Extra Usage", …).
///
/// Titles stay English in the model on purpose: a descriptor's title doubles as its `metricLabel`
/// match key against `MetricLine.label`, the local HTTP API and the CLI export them, and layouts
/// persist them. Views translate a title only when they draw it. The keys are listed by hand in
/// `Localizable.xcstrings` (extraction state "manual"), because the compiler can't extract a
/// runtime string; `LocalizationCatalogTests` checks every descriptor title has an entry.
enum LocalizedMetricTitle {
    /// The title in the app's language, or the English title when the catalog has no entry.
    static func string(_ title: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: title, value: title, table: "Localizable")
    }
}
