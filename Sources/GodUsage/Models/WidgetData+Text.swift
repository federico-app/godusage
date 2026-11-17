import Foundation

/// The row text that pairs a value with an English word from a descriptor ("left", "spent", "limit"),
/// as full localizable phrases. Descriptors keep the English word as data; it becomes words in the
/// app's language only here, at display.
extension WidgetData {
    /// "95% left" / "5% used": a meter reading followed by its Used/Left mode.
    static func reading(_ value: String, mode: WidgetDisplayMode) -> String {
        switch mode {
        case .used:
            String(localized: "\(value) used", comment: "A meter reading in Used mode, e.g. 5% used or $12.00 used")
        case .remaining:
            String(localized: "\(value) left", comment: "A meter reading in Left mode or a remaining balance, e.g. 95% left or $1,503.00 left")
        }
    }

    /// "$4.08 spent", "$1,503.00 left", "$100 limit": a value followed by a descriptor's word. An unknown
    /// word stays as given.
    static func valueWithWord(_ value: String, _ word: String) -> String {
        switch word {
        case "left": reading(value, mode: .remaining)
        case "used": reading(value, mode: .used)
        case "spent": String(localized: "\(value) spent", comment: "A spend amount, e.g. $4.08 spent")
        case "limit": String(localized: "\(value) limit", comment: "A dollar limit under a meter, e.g. $100 limit")
        case "purchased": String(localized: "\(value) purchased", comment: "Credits bought, under a meter, e.g. $100 purchased")
        default: "\(value) \(word)"
        }
    }
}
