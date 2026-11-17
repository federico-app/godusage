import SwiftUI

/// The top of an expanded member row: the name on its own line with the value on the right, then
/// the You chip and the gold chips (today's top spender, last month's champion).
struct TeamMemberExpandedHeader: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let isMe: Bool
    let value: String
    let teamID: String?
    var valueFont: Font = .callout

    private var awards: [MemberDetailFormat.Award] {
        guard let teamID else { return [] }
        let social = container.teamsSocial
        let champion = social.lastMonthChampion(teamID: teamID)
        return MemberDetailFormat.awards(
            isTopToday: social.kingOfTheDay(teamID: teamID)?.userID == member.userID,
            champion: champion?.userID == member.userID ? champion : nil
        )
    }

    var body: some View {
        let awards = self.awards
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(member.displayName)
                    .font(valueFont.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text(value)
                    .font(valueFont.monospacedDigit().weight(.semibold))
                    .layoutPriority(2)
            }
            if isMe || !awards.isEmpty {
                HStack(spacing: 6) {
                    if isMe { YouChip() }
                    ForEach(awards, id: \.symbol) { award in
                        MemberAwardChip(award: award)
                    }
                }
            }
        }
    }
}

/// A gold capsule with a symbol and a short text ("Top today"); the full sentence on hover.
struct MemberAwardChip: View {
    let award: MemberDetailFormat.Award

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: award.symbol).font(.system(size: 9, weight: .semibold))
            Text(award.title).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(MemberBadges.gold)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(MemberBadges.gold.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(award.detail)
        .hoverTooltip(award.detail)
    }
}

/// What opens under a member on the dashboard: four tiles (last hour, month pace, efficiency,
/// place), their providers (with two or more) and models as shares, the reaction buttons with who
/// reacted today, and when they last synced.
struct TeamMemberDetail: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let stats: TeamStats
    let metric: TeamMetric
    let range: StatsRange
    let teamID: String?
    let providerName: (String) -> String
    var now = Date()

    var body: some View {
        let providers = MemberDetailFormat.providerShares(member.providers, metric: metric, providerName: providerName)
        let models = MemberDetailFormat.modelShares(stats.models, userID: member.userID, metric: metric)
        let hasUsage = member.providers.contains { MemberDetailFormat.weight($0.totals, metric: metric) > 0 }
        VStack(alignment: .leading, spacing: 12) {
            tiles
            if !hasUsage {
                Text("No usage in this period.").font(.caption).foregroundStyle(.secondary)
            }
            if !providers.isEmpty {
                MemberShareList(title: MemberDetailFormat.listTitle("Providers", range: range), shares: providers, metric: metric) {
                    TotalSpendPalette.color(for: $0.provider ?? "")
                }
            }
            if !models.isEmpty {
                let colors = modelColors
                MemberShareList(title: MemberDetailFormat.listTitle("Models", range: range), shares: models, metric: metric) { share in
                    colors[share.id] ?? share.provider.map(TotalSpendPalette.color(for:)) ?? Color.secondary.opacity(0.35)
                }
            }
            if let teamID { reactions(teamID: teamID) }
            footer
        }
    }

    private var tiles: some View {
        var tiles: [MemberDetailFormat.Tile] = []
        if let teamID {
            tiles.append(MemberDetailFormat.lastHourTile(container.teams.momentumByTeam[teamID]?[member.userID]))
            if let projection = container.teamsSocial.projection(teamID: teamID, userID: member.userID), projection.spentSoFar > 0 {
                tiles.append(MemberDetailFormat.paceTile(projection))
            }
        }
        if let efficiency = MemberDetailFormat.efficiencyTile(member.totals) { tiles.append(efficiency) }
        tiles.append(MemberDetailFormat.placeTile(
            rank: member.rank, of: stats.members.count, rankChange: member.rankChange,
            hasUsage: member.costUSD > 0 || member.tokens > 0, range: range
        ))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(tiles, id: \.label) { MemberDetailTile(tile: $0) }
        }
    }

    /// The same shades the Teams window's models chart gives each model.
    private var modelColors: [String: Color] {
        TeamModelPalette.colors(for: stats.models.filter { $0.totals.value(for: metric.sort) > 0 }.map { ($0.provider, $0.model) })
    }

    private func reactions(teamID: String) -> some View {
        let reactions = container.teamsSocial.reactions(teamID: teamID, userID: member.userID)
        let names = Dictionary(stats.members.map { ($0.userID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let givers = MemberDetailFormat.reactionGivers(reactions, names: names, me: container.teams.user?.id)
        return HStack(spacing: 8) {
            ReactionButtons(teamID: teamID, member: member)
                .fixedSize()
            Spacer(minLength: 6)
            if let givers {
                Text(givers.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .hoverTooltip(givers.detail)
                    .accessibilityLabel("Reacted today: \(givers.detail)")
            }
        }
    }

    private var footer: some View {
        let newest = TeamsFormat.newestVersion(stats.members)
        let outdated = TeamsFormat.isOutdated(member.appVersion, newest: newest)
        return HStack(spacing: 6) {
            Text(MemberDetailFormat.footerText(lastSyncAt: member.lastSyncAt, appVersion: member.appVersion, isOutdated: outdated, now: now))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            OutdatedVersionChip(version: member.appVersion, newestVersion: newest)
        }
    }
}

/// One tile: a small uppercase label, a big number, one line of context.
struct MemberDetailTile: View {
    let tile: MemberDetailFormat.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tile.value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(tile.isNotice ? Theme.notice : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tile.context)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
    }
}

/// "MODELS TODAY", a thin bar of each row's share, then one row per item: dot, name, share, value.
struct MemberShareList: View {
    let title: String
    let shares: [MemberDetailFormat.Share]
    let metric: TeamMetric
    let color: (MemberDetailFormat.Share) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                let gaps = CGFloat(max(shares.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        Rectangle()
                            .fill(color(share))
                            .frame(width: max(1, (proxy.size.width - gaps) * share.fraction))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            ForEach(shares) { share in
                HStack(spacing: 8) {
                    Circle().fill(color(share)).frame(width: 7, height: 7)
                    Text(share.title).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(MemberDetailFormat.percentText(share.fraction))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(metric.format(share.totals))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
