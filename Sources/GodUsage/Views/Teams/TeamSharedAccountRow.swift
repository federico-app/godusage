import SwiftUI

/// A shared account on the ranking: unranked, below the members, with who shares it. Its usage is in
/// the team total but in no member's, because the provider does not split it per person.
struct TeamSharedAccountRow: View {
    let account: TeamStats.SharedAccount
    let stats: TeamStats
    let metric: TeamMetric
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
                    Text(metric.format(account.totals))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ProviderSplitBar(
                    providers: metric.barSegments(
                        [TeamStats.ProviderTotals(provider: account.provider, tokens: account.tokens, costUSD: account.costUSD)],
                        total: account.totals
                    ),
                    top: top,
                    sort: metric.sort,
                    height: barHeight
                )
                .opacity(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shared \(providerName(account.provider)) account, used by \(stats.sharedMemberNames(account))")
    }
}

/// "Not synced for 3 days" under a member whose newest upload is more than 24 hours old, so stale
/// numbers aren't read as no usage. Shows nothing otherwise.
struct TeamSyncNote: View {
    let member: TeamStats.Member
    var now = Date()

    var body: some View {
        if let note = TeamsFormat.syncNote(member.lastSyncAt, now: now) {
            Label(note, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
    }
}

extension TeamsFormat {
    /// "Not synced for 2 days" once `lastSyncAt` is more than 24 hours old; nil when recent or unknown.
    static func syncNote(_ lastSyncAt: String?, now: Date) -> String? {
        guard let lastSyncAt, let date = syncDate(lastSyncAt) else { return nil }
        let hours = now.timeIntervalSince(date) / 3600
        guard hours > 24 else { return nil }
        let days = Int(hours / 24)
        return "Not synced for \(days) \(days == 1 ? "day" : "days")"
    }

    private static func syncDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension TeamStats {
    /// Shared accounts with usage in this metric, largest first.
    func sharedAccounts(for metric: TeamMetric) -> [SharedAccount] {
        (shared ?? []).filter { metric.value($0.totals) > 0 }.sorted { metric.value($0.totals) > metric.value($1.totals) }
    }

    /// The longest bar on the ranking, so member and shared bars share one scale.
    func rankingTop(for metric: TeamMetric) -> Double {
        (members.map { metric.value($0.totals) } + sharedAccounts(for: metric).map { metric.value($0.totals) }).max() ?? 0
    }
}
