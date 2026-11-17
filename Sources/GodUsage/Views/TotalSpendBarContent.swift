import SwiftUI

/// The Total Spend body, the same for every period and metric: the big total, one bar split into
/// each provider's share (largest first, matching the legend), and the ranked legend. Shared by the
/// live card and the share-card export so the PNG can't drift from what's on screen. Segments are
/// keyed by provider ID, so a period or metric switch slides each provider's piece to its new width.
struct TotalSpendBarContent: View {
    let projection: TotalSpendProjection

    private let density = DensitySetting.compact
    private static let barHeight: CGFloat = 8
    private static let segmentGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(projection.headline(projection.centerValue))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Digits roll up or down to the new total on a period or metric switch.
                .contentTransition(.numericText(value: projection.centerValue))
                .hoverTooltip(tooltip)
            bar
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bar: some View {
        let segments = projection.barSegments
        let gaps = Self.segmentGap * CGFloat(max(segments.count - 1, 0))
        return GeometryReader { proxy in
            let usable = max(proxy.size.width - gaps, 0)
            HStack(spacing: Self.segmentGap) {
                ForEach(segments) { segment in
                    Capsule()
                        .fill(TotalSpendPalette.color(for: segment.providerID))
                        .frame(width: usable * segment.share)
                }
            }
        }
        .frame(height: Self.barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(projection.slices) { slice in
                TotalSpendLegendRow(
                    title: slice.title,
                    account: slice.account,
                    value: projection.formatted(slice.displayAmount, style: projection.legendValueStyle),
                    color: TotalSpendPalette.color(for: slice.provider.id),
                    fontSize: density.supportingPointSize
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        let total = projection.formatted(projection.centerValue, style: .full)
        let count = projection.slices.count
        switch projection.metric {
        case .cost:
            return String(localized: "Total cost \(total) across \(count) providers", comment: "Accessibility: the Total Spend bar")
        case .tokens:
            return String(localized: "Total tokens \(total) across \(count) providers", comment: "Accessibility: the Total Spend bar")
        case .costPerMtok:
            return String(localized: "Blended cost per million tokens \(total) across \(count) providers", comment: "Accessibility: the Total Spend bar")
        }
    }

    /// The estimate note on dollar metrics, as the old ring center carried it.
    private var tooltip: String? {
        guard projection.isEstimated, projection.metric.usesDollarEstimateNote else { return nil }
        return "\(projection.formatted(projection.centerValue, style: .full)) · \(WidgetData.localEstimateNote)"
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

    /// The headline total: exact cents for dollars ("$26.26"), the ring center's short form with
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
