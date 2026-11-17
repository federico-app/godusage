import AppKit
import SwiftUI

/// The dashboard's cross-provider Total Spend section: a native segmented period picker
/// (Today / Yesterday / Last 30 Days) over a bar whose segments are each provider's share of
/// the selected metric, with the total above it and a ranked legend below. The title is a
/// pull-down menu for Cost / Cost/MTok / Tokens. Data comes from `TotalSpendAggregator` over
/// the same snapshots the provider cards render. Shown whenever any enabled provider tracks spend
/// (`LayoutStore.hasSpendCapableProvider`) and the toggle at the top of Settings is on; a period
/// (or metric) with nothing to show uses a quiet empty state instead of hiding the card.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(AppContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace

    /// The selected period survives popover closes and relaunches, like the meter-style toggles.
    @AppStorage("godusage.totalSpend.period") private var periodRawValue = TotalSpendPeriod.today.rawValue
    /// The selected metric (Cost / Cost/MTok / Tokens) survives the same way.
    @AppStorage("godusage.totalSpend.metric") private var metricRawValue = TotalSpendMetric.cost.rawValue
    /// The switcher fell back to segments sized to their short titles, so the header names the period.
    @State private var usesCompactPicker = false
    private let density = DensitySetting.compact

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    /// The spend-tile providers the card may aggregate — capability-based (see
    /// `LayoutStore.spendCapableProviders`), so a provider stays counted even when its own rows are
    /// hidden in Customize, and providers with merely similar-looking dollar rows never leak in.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        // Titles resolve here — the one place with registry access — so the legend AND the share
        // export (rendered outside the environment) carry live renames.
        return TotalSpendAggregator.total(
            for: period,
            providers: providers,
            snapshots: dataStore.snapshots,
            title: { container.displayParts(for: $0).name },
            account: { container.displayParts(for: $0).account }
        )
    }

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            // Computed once per body evaluation: `projection` re-copies the snapshots dictionary
            // and re-aggregates every provider, so reading the computed property per subview use
            // multiplies that work.
            card(projection: projection)
        }
    }

    // MARK: - Header

    /// Section header matching the provider headers' scale: title menu leading, the share control
    /// trailing where a provider header shows its mark.
    private var header: some View {
        HStack(spacing: 5) {
            metricMenu
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            if usesCompactPicker {
                Text(period.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DevBuildBadge()
                .padding(.leading, 3)
            Spacer(minLength: 8)
            shareButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    /// Title that is itself the metric switch — a plain pull-down with zero extra chrome. A real
    /// `NSMenu` via `NativeMenuButton`, not a SwiftUI `Menu`: the SwiftUI popup could open at a
    /// stale width and middle-truncate "Cost/MTok".
    private var metricMenu: some View {
        NativeMenuButton(
            accessibilityLabel: "Total Spend Metric",
            accessibilityValue: metric.title
        ) {
            TotalSpendMetric.allCases.map { option in
                let item = ClosureMenuItem(title: option.title) {
                    metricRawValue = option.rawValue
                }
                item.state = option == metric ? .on : .off
                return item
            }
        } label: {
            HStack(spacing: 4) {
                Text(metric.title)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Names the providers actually feeding the bar — the enabled spend-capable set — instead of a
    /// hardcoded list, so disabling a provider (or a new spend provider shipping) can't make the
    /// tooltip lie about what the total reflects.
    private var infoTooltip: String {
        let names = providers.map { container.displayName(for: $0) }
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var shareButton: some View {
        CopyFeedbackButton(accessibilityLabel: "Copy \(metric.title) Screenshot") {
            ShareCardRenderer.shareTotalSpend(
                total: total,
                metric: metric,
                appearance: colorScheme,
                layout: layout
            )
        }
    }

    // MARK: - Card

    private func card(projection: TotalSpendProjection) -> some View {
        VStack(spacing: 12) {
            periodPicker
            if projection.isEmpty {
                emptyState
            } else {
                TotalSpendBarContent(projection: projection)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .animation(Motion.spring, value: metricRawValue)
        .contextMenu {
            Button("Share Screenshot") {
                ShareCardRenderer.shareTotalSpend(
                    total: total,
                    metric: metric,
                    appearance: colorScheme,
                    layout: layout
                )
            }
        }
    }

    /// A capsule segmented switcher in the app's own design language (the footer's glass capsule
    /// controls), replacing the stock `.segmented` picker whose legacy rounded-rect chrome clashes
    /// with the Tahoe look. The selected segment is a Liquid Glass capsule (frosted material on
    /// macOS 15) that slides between segments via `matchedGeometryEffect`.
    ///
    /// Four equal segments when every title fits whole; otherwise each segment is as wide as its
    /// short title ("7d", "30d") and the header names the period in full.
    private var periodPicker: some View {
        ViewThatFits(in: .horizontal) {
            segments(equal: true)
                .frame(minWidth: Self.equalPickerWidth)
            segments(equal: false)
                .onAppear { usesCompactPicker = true }
                .onDisappear { usesCompactPicker = false }
        }
        .frame(maxWidth: .infinity)
    }

    private static let segmentFontSize: CGFloat = 11
    private static let equalSegmentPadding: CGFloat = 4
    private static let segmentSpacing: CGFloat = 2
    private static let pickerInset: CGFloat = 3

    /// The narrowest width at which four equal segments show every title whole (bold, as when selected).
    private static let equalPickerWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: segmentFontSize, weight: .semibold)
        let widest = TotalSpendPeriod.allCases
            .map { ceil(($0.shortLabel as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        let count = CGFloat(TotalSpendPeriod.allCases.count)
        return count * (widest + 2 * equalSegmentPadding) + (count - 1) * segmentSpacing + 2 * pickerInset
    }()

    private func segments(equal: Bool) -> some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate, equal: equal)
            }
        }
        .padding(Self.pickerInset)
        .background(.quinary, in: Capsule())
    }

    private func periodSegment(_ candidate: TotalSpendPeriod, equal: Bool) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(equal ? candidate.shortLabel : candidate.tinyLabel)
                .font(.system(size: Self.segmentFontSize, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, equal ? Self.equalSegmentPadding : 8)
                .padding(.vertical, 4)
                .frame(maxWidth: equal ? .infinity : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.rawValue)
        .hoverTooltip(equal || candidate.tinyLabel == candidate.rawValue ? nil : candidate.rawValue)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// A metric/period combination with nothing to show mirrors the spend tiles' "No data" rule —
    /// never a fabricated zero bar.
    private var emptyState: some View {
        Text(metric.emptyMessage)
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// Stable per-provider brand tints for the Total Spend bar and legend — the one place the app maps
/// a provider to a color, so the chart, legend, and share card always agree. Colors are keyed by
/// provider ID only (never by rank or position), so a provider keeps its color across period
/// switches, re-sorts, and launches. Hexes come from the legacy edition's per-plugin `brandColor`
/// values; brands whose color is plain black (Cursor, Grok) get adaptive near-black/near-white
/// dynamic colors so they read on both appearances without both landing on the same gray.
enum TotalSpendPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),                             // Claude terracotta
        "codex": hex(0x10A37F),                              // OpenAI green (#10A37F)
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),  // brand black (#13120A), flipped near-white in dark mode
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),    // brand black, offset to gray next to Cursor
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),  // OpenCode — grayscale brand, medium gray
        "openrouter": hex(0x6467F2),                         // OpenRouter indigo
        "antigravity": hex(0x4285F4),                        // Google blue
        "copilot": hex(0xA855F7),                            // Copilot purple
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    /// Deterministic backstop hues for a provider that ships without a palette entry — keyed off the
    /// provider ID (not rank), so the color holds steady across periods and launches.
    private static let fallback: [Color] = [
        hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)
    ]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A light/dark-adaptive color, for brands whose mark is pure black — invisible on a dark card
    /// unless flipped.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
