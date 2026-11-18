import SwiftUI

/// The Mac's Total Spend card for your own usage: Cost (with DEV in dev builds), the period picker,
/// the big total, one bar split into each provider's share, and the ranked legend. Without a provider
/// split for the period (servers before per-day providers), only the total shows.
struct CostCard: View {
    let usage: MyUsage
    @Binding var period: BoardRange

    private var total: UsagePeriodTotal { usage.total(for: period) }

    var body: some View {
        let total = total
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Cost").font(.headline)
                DevBuildBadge()
                Spacer()
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $period) {
                    ForEach(BoardRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if total.costUSD <= 0, total.tokens == 0 {
                    Text("No cost data for this period")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    content(total)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .animation(.snappy, value: period)
    }

    private func content(_ total: UsagePeriodTotal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TeamsFormat.cost(total.costUSD))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: total.costUSD))
            if let providers = total.providers?.filter({ $0.costUSD > 0 }), !providers.isEmpty {
                SpendSplitBar(providers: providers)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(providers) { provider in
                        HStack(spacing: 8) {
                            Circle().fill(ProviderPalette.color(for: provider.provider)).frame(width: 8, height: 8)
                            Text(TeamsFormat.providerName(provider.provider))
                            Spacer(minLength: 8)
                            Text(TeamsFormat.cost(provider.costUSD)).monospacedDigit()
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bar split into each provider's share of the spend, largest first, with a small gap between.
struct SpendSplitBar: View {
    let providers: [ProviderTotals]

    var body: some View {
        let total = providers.reduce(0) { $0 + $1.costUSD }
        GeometryReader { proxy in
            let gaps = 2 * CGFloat(max(providers.count - 1, 0))
            let usable = max(proxy.size.width - gaps, 0)
            HStack(spacing: 2) {
                ForEach(providers) { provider in
                    Capsule()
                        .fill(ProviderPalette.color(for: provider.provider))
                        .frame(width: total > 0 ? usable * provider.costUSD / total : 0)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
