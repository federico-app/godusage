import SwiftUI

/// The grouped metric-card body shared by the live dashboard list and its lifted drag preview:
/// a spacing-0 stack of rows (separated by row padding; the only line is the expanded-section
/// separator), the density gutter that
/// keeps the first/last row off the card edge, and the shared card surface. Both surfaces build the
/// card through this so the floating preview can't drift from the live card (it once hard-coded its
/// spacing and even drew dividers the live list doesn't).
///
/// The live list threads per-row gestures/opacity/frames through `rows`; the preview passes plain
/// `WidgetRowView`s; the preview's shadow supplies its lifted depth.
struct DashboardMetricCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    private let density = DensitySetting.compact

    var body: some View {
        VStack(spacing: 0) {
            rows
        }
        .padding(.vertical, density.cardGutter)
        .cardSurface()
    }
}

/// The thin line between a provider card's Always Visible rows and its expanded section (On Demand
/// rows, then quick links). Shown only while the card is open; it is also the drop target for
/// dragging a metric across the boundary.
struct DashboardMetricCardSeparator: View {
    static let verticalPadding: CGFloat = 5
    /// Rendered height (hairline plus padding), used by `ExpansionHeightEstimator`.
    static let height: CGFloat = 1 + verticalPadding * 2

    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, Self.verticalPadding)
            .contentShape(Rectangle())
    }
}

/// The centered caret at the bottom of a provider card that reveals or hides its expanded section.
/// Shared by the live card and the lifted drag preview (which passes an inert action).
struct DashboardMetricCardCaret: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }
}
