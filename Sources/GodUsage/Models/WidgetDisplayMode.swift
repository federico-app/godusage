import Foundation

enum WidgetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case used
    case remaining

    /// "Left" is the established wording for remaining headroom.
    var label: String {
        switch self {
        case .used: return String(localized: "Used", comment: "Meter mode: show the share used; also lowercased after a value, e.g. 5% used")
        case .remaining: return String(localized: "Left", comment: "Meter mode: show the share remaining; also lowercased after a value, e.g. 95% left")
        }
    }

    mutating func toggle() {
        self = self == .used ? .remaining : .used
    }
}
