import SwiftUI

/// Model colors: each model takes its provider's color (`TotalSpendPalette`), shaded by its place
/// among that provider's models in the period, so Opus 5.5, Opus 5, and Sonnet read as three
/// Claude tones while staying recognizably Claude.
enum TeamModelPalette {
    /// Lighter and darker steps, alternating so neighboring models of one provider stay apart.
    private static let shades: [(toward: Color, amount: Double)] = [
        (.white, 0), (.white, 0.38), (.black, 0.32), (.white, 0.62), (.black, 0.52), (.white, 0.78),
    ]

    /// Colors by model id (`provider/model`), for models in usage order (largest first).
    static func colors(for models: [(provider: String, model: String)]) -> [String: Color] {
        var seen: [String: Int] = [:]
        var colors: [String: Color] = [:]
        for item in models {
            let id = "\(item.provider)/\(item.model)"
            guard colors[id] == nil else { continue }
            let index = seen[item.provider, default: 0]
            seen[item.provider] = index + 1
            colors[id] = shade(TotalSpendPalette.color(for: item.provider), index: index)
        }
        return colors
    }

    static func shade(_ base: Color, index: Int) -> Color {
        let step = shades[index % shades.count]
        return step.amount > 0 ? base.mix(with: step.toward, by: step.amount) : base
    }
}
