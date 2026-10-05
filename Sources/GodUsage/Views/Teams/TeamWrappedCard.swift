import AppKit
import SwiftUI

/// The shareable "Wrapped" image: your standing in a team over the last 30 days or 12 months, with
/// the team's top five. Rendered off-screen and copied to the clipboard like Share Screenshot.
struct TeamWrappedCard: View {
    let teamName: String
    let periodTitle: String
    let stats: TeamStats
    let me: TeamStats.Member?
    let providerName: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GODUSAGE WRAPPED")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(teamName).font(.title2.weight(.bold))
                Text(periodTitle).font(.callout).foregroundStyle(.secondary)
            }

            if let me {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("#\(me.rank)")
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    Text("of \(stats.members.count)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 18) {
                    stat("Spend", Formatters.currency(me.costUSD))
                    stat("Tokens", TeamsFormat.tokens(me.tokens))
                    if let perMillion = me.totals.costPerMillionTokens {
                        stat("Per 1M Tokens", Formatters.currency(perMillion))
                    }
                }
                HStack(spacing: 18) {
                    if let top = me.providers.first(where: { $0.costUSD > 0 }) {
                        labeled("Top Provider") {
                            HStack(spacing: 5) {
                                Circle().fill(TotalSpendPalette.color(for: top.provider)).frame(width: 8, height: 8)
                                Text(providerName(top.provider)).font(.callout.weight(.semibold))
                            }
                        }
                    }
                    if let model = topModel(for: me.userID) {
                        labeled("Top Model") {
                            Text(model).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("TEAM").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                let top = stats.members.first?.costUSD ?? 0
                ForEach(stats.members.prefix(5)) { member in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(member.rank)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 16, alignment: .trailing)
                            Text(member.displayName)
                                .font(.callout.weight(member.userID == me?.userID ? .bold : .regular))
                                .lineLimit(1)
                            Spacer()
                            Text(Formatters.currency(member.costUSD)).font(.callout.monospacedDigit())
                        }
                        ProviderSplitBar(providers: member.providers, top: top, sort: .cost, height: 5)
                            .padding(.leading, 22)
                    }
                }
                HStack {
                    Text("Team total").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.currency(stats.totals.costUSD)).font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(width: 380, alignment: .leading)
        .background(Theme.traySurface)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        labeled(title) { Text(value).font(.title3.weight(.semibold).monospacedDigit()) }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func topModel(for userID: String) -> String? {
        stats.models
            .compactMap { model in model.members.first { $0.userID == userID }.map { (model.model, $0.costUSD) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }
}

@MainActor
enum TeamWrapped {
    enum Period: CaseIterable {
        case month
        case year

        var range: StatsRange { self == .month ? .month : .year }
        var menuTitle: String { self == .month ? "Last 30 Days" : "Last 12 Months" }
    }

    /// Loads the period's stats, renders the card in `appearance`, and copies the PNG. Returns
    /// whether it reached the clipboard; failures are logged (and beep, like Share Screenshot).
    static func share(
        period: Period,
        teamID: String,
        teamName: String,
        teams: TeamsStore,
        appearance: ColorScheme,
        providerName: @escaping (String) -> String
    ) async -> Bool {
        let stats: TeamStats
        do {
            stats = try await teams.stats(for: teamID, range: period.range, sort: .cost)
        } catch {
            AppLog.error(.teams, "wrapped: couldn't load stats: \(error.localizedDescription)")
            ShareCardRenderer.playAlertSound()
            return false
        }
        let card = TeamWrappedCard(
            teamName: teamName,
            periodTitle: period.menuTitle,
            stats: stats,
            me: stats.members.first { $0.userID == teams.user?.id },
            providerName: providerName
        )
        .environment(\.colorScheme, appearance)
        guard let image = ShareCardRenderer.image(for: card) else {
            AppLog.error(.teams, "wrapped: ImageRenderer produced no image")
            ShareCardRenderer.playAlertSound()
            return false
        }
        return ShareCardRenderer.copyToPasteboard(image)
    }
}
