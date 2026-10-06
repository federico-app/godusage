import SwiftUI

/// A shared account on the ranking: unranked, below the members, with who shares it. Its usage is in
/// the team total but in no member's, because the provider does not split it per person.
struct TeamSharedAccountRow: View {
    let account: TeamStats.SharedAccount
    let stats: TeamStats
    let sort: StatsSort
    let top: Double
    let providerName: (String) -> String
    var barHeight: CGFloat = 5

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Shared \(providerName(account.provider))").lineLimit(1)
                    Text(stats.sharedMemberNames(account))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(TeamsFormat.value(account.totals, sort: sort))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ProviderSplitBar(
                    providers: [TeamStats.ProviderTotals(provider: account.provider, tokens: account.tokens, costUSD: account.costUSD)],
                    top: top,
                    sort: sort,
                    height: barHeight
                )
                .opacity(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shared \(providerName(account.provider)) account, used by \(stats.sharedMemberNames(account))")
    }
}

extension TeamStats {
    /// Shared accounts with usage in this metric, largest first.
    func sharedAccounts(for sort: StatsSort) -> [SharedAccount] {
        (shared ?? []).filter { $0.totals.value(for: sort) > 0 }
    }

    /// The longest bar on the ranking, so member and shared bars share one scale.
    func rankingTop(for sort: StatsSort) -> Double {
        (members.map { $0.totals.value(for: sort) } + sharedAccounts(for: sort).map { $0.totals.value(for: sort) }).max() ?? 0
    }
}
