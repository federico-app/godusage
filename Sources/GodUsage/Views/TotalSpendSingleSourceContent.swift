import SwiftUI

/// The Total Spend body when one source fed the whole total: a big total, one full-width bar in that
/// source's color, and its legend row. A one-color ring says nothing a bar doesn't, and the number
/// reads better large. Shared by the live card and the share card through `TotalSpendRingContent`.
struct TotalSpendSingleSourceContent: View {
    let projection: TotalSpendProjection
    let slice: TotalSpendProjectedSlice

    private let density = DensitySetting.compact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(projection.headline(slice.displayAmount))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .hoverTooltip(tooltip)
            Capsule()
                .fill(TotalSpendPalette.color(for: slice.provider.id))
                .frame(height: 8)
                .accessibilityHidden(true)
            TotalSpendLegendRow(
                title: slice.title,
                account: slice.account,
                value: projection.formatted(slice.displayAmount, style: projection.legendValueStyle),
                color: TotalSpendPalette.color(for: slice.provider.id),
                fontSize: density.supportingPointSize
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The estimate note, as the ring center's tooltip carries it.
    private var tooltip: String? {
        guard projection.isEstimated, projection.metric.usesDollarEstimateNote else { return nil }
        return WidgetData.localEstimateNote
    }
}

extension TotalSpendProjection {
    /// Legend amounts: tokens always abbreviated; dollar modes keep exact cents.
    var legendValueStyle: MetricFormatter.Style {
        switch metric {
        case .tokens: .row
        case .cost, .costPerMtok: .full
        }
    }

    /// One amount under this projection's metric.
    func formatted(_ value: Double, style: MetricFormatter.Style) -> String {
        switch metric {
        case .cost: MetricFormatter.number(value, kind: .dollars, style: style)
        case .tokens: MetricFormatter.number(value, kind: .count, style: style)
        case .costPerMtok: MetricFormatter.costPerMtok(value, style: style)
        }
    }

    /// The single-source total: exact cents for dollars ("$26.26"), the ring center's short form with
    /// its unit for tokens ("12.4 million").
    func headline(_ value: Double) -> String {
        switch metric {
        case .cost, .costPerMtok:
            return formatted(value, style: .full)
        case .tokens:
            let center = MetricFormatter.totalSpendRingCenter(value, metric: metric)
            return center.unit.map { "\(center.primary) \($0)" } ?? center.primary
        }
    }
}
