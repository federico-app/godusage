import SwiftUI

/// The dashboard's Team section, under Total Spend once you're signed in and in a team: the
/// selected team's ranking at a glance, with each member's split by provider. Click a member for their
/// providers and top models. Advanced Stats opens the Teams window with the full charts.
struct TeamDashboardSection: View {
    @Environment(AppContainer.self) private var container

    /// The Total Spend card's period switcher drives this section too (Today, Yesterday, 30 Days).
    @AppStorage("godusage.totalSpend.period") private var totalSpendPeriod = TotalSpendPeriod.today.rawValue
    /// The Total Spend card's metric menu drives this section too (Cost, Cost/MTok, Tokens).
    @AppStorage("godusage.totalSpend.metric") private var totalSpendMetric = TotalSpendMetric.cost.rawValue
    /// The popover's tree survives closing, so reloads key off visibility, not appearance.
    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @State private var expandedMemberID: String?
    @State private var isLoading = false

    private let density = DensitySetting.compact

    private var metric: TeamMetric { TeamMetric(TotalSpendMetric(rawValue: totalSpendMetric) ?? .cost) }
    private var sort: StatsSort { metric.sort }

    private var period: TotalSpendPeriod { TotalSpendPeriod(rawValue: totalSpendPeriod) ?? .today }
    /// Yesterday is the server's one-day range ending yesterday.
    private var range: StatsRange { period == .last30 ? .month : .today }
    private var endingOn: String? {
        guard period == .yesterday, let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        return DailyUsageAccumulator.dayKey(from: yesterday, calendar: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            content
        }
        .frame(maxWidth: .infinity)
        .task(id: loadKey) { await keepLoaded() }
    }

    private struct LoadKey: Hashable {
        var isVisible: Bool
        var teamID: String?
        var range: StatsRange
        var sort: StatsSort
        var endingOn: String?
    }

    private var loadKey: LoadKey {
        LoadKey(isVisible: popoverIsVisible, teamID: container.teams.selectedTeamID, range: range, sort: sort, endingOn: endingOn)
    }

    private var stats: TeamStats? {
        guard let teamID = container.teams.selectedTeamID else { return nil }
        return container.teams.cachedStats[TeamsStore.StatsKey(teamID: teamID, range: range, sort: sort, endingOn: endingOn)]
    }

    /// Loads on every open and keeps reloading while the popover stays open, so teammates' new
    /// usage shows up without reopening. Stops when the popover closes (the task is cancelled).
    private func keepLoaded() async {
        guard popoverIsVisible else {
            // Prewarm while hidden, so the first open isn't a spinner.
            if stats == nil { await load() }
            return
        }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: Self.reloadInterval)
        }
    }

    private static let reloadInterval: Duration = .seconds(120)

    private func load() async {
        let teams = container.teams
        if teams.teams.isEmpty, teams.isSignedIn { await teams.refresh() }
        guard let teamID = teams.selectedTeamID else { return }
        isLoading = true
        await teams.loadStats(teamID: teamID, range: range, sort: sort, endingOn: endingOn)
        isLoading = false
        // Today's leader (👑), the month-to-date projection, and challenges, alongside the board.
        if period != .today || sort != .cost { await teams.loadStats(teamID: teamID, range: .today, sort: .cost) }
        await teams.loadStats(teamID: teamID, range: .monthToDate, sort: .cost)
        await container.teamsSocial.loadChallenges(teamID: teamID)
    }

    @ViewBuilder
    private var content: some View {
        let teams = container.teams
        controls
        if let stats {
            summary(stats)
            ranking(stats)
            challengesCard
        } else if let error = teams.statsError {
            errorCard(error)
        } else {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 24)
        }
        if stats != nil, let error = teams.statsError {
            Text(error).font(.caption).foregroundStyle(Theme.notice)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            teamPicker
            Spacer(minLength: 4)
            if isLoading { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder
    private var teamPicker: some View {
        let teams = container.teams
        if teams.teams.count > 1 {
            Menu {
                ForEach(teams.teams) { team in
                    Button(team.name) { teams.selectedTeamID = team.id }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currentTeamName).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(currentTeamName).font(.headline).lineLimit(1)
        }
    }

    private var currentTeamName: String {
        let teams = container.teams
        return teams.teams.first { $0.id == teams.selectedTeamID }?.name ?? "Team"
    }

    // MARK: - Board

    private func summary(_ stats: TeamStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.format(stats.totals))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(metric.teamLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let teamID = container.teams.selectedTeamID, let projection = container.teamsSocial.projection(teamID: teamID) {
                ProjectionText(projection: projection, prefix: "Team on pace for")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var challengesCard: some View {
        if let teamID = container.teams.selectedTeamID {
            let active = container.teamsSocial.challenges(teamID: teamID).filter { !$0.finished }
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(active.prefix(3).enumerated()), id: \.element.id) { index, challenge in
                        if index > 0 { Divider() }
                        ChallengeSummaryRow(challenge: challenge, me: container.teams.user?.id)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .cardSurface()
            }
        }
    }

    private func ranking(_ stats: TeamStats) -> some View {
        let top = stats.rankingTop(for: metric)
        return VStack(spacing: 0) {
            ForEach(Array(metric.ranked(stats.members).enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 12) }
                memberRow(member, top: top, stats: stats)
            }
            ForEach(stats.sharedAccounts(for: metric)) { account in
                Divider().padding(.leading, 12)
                TeamSharedAccountRow(account: account, stats: stats, metric: metric, top: top, providerName: providerName)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            Divider()
            advancedStatsRow
        }
        .cardSurface()
    }

    /// Opens the Teams window: every range, charts, models, and the two-member comparison.
    private var advancedStatsRow: some View {
        Button { TeamsWindowLink.open() } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Advanced Stats")
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Advanced Stats")
    }

    private func memberRow(_ member: TeamStats.Member, top: Double, stats: TeamStats) -> some View {
        let isExpanded = expandedMemberID == member.userID
        let isMe = member.userID == container.teams.user?.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spring) { expandedMemberID = isExpanded ? nil : member.userID }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(member.rank)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(member.rank == 1 ? .primary : .secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(member.displayName)
                            .fontWeight(isMe ? .semibold : .regular)
                            .lineLimit(1)
                        if isMe {
                            Text("You")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                        // Movement compares server ranks, which Cost/MTok re-ranks.
                        if metric != .costPerMtok {
                            RankChangeBadge(member: member, range: range, sort: sort)
                        }
                        if let teamID = container.teams.selectedTeamID {
                            MemberBadges(teamID: teamID, userID: member.userID)
                        }
                        Spacer(minLength: 6)
                        if let teamID = container.teams.selectedTeamID {
                            ReactionCounts(reactions: container.teamsSocial.reactions(teamID: teamID, userID: member.userID))
                        }
                        Text(metric.format(member.totals))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    providerBar(member, top: top)
                        .padding(.leading, 26)
                    TeamSyncNote(member: member)
                        .padding(.leading, 26)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                memberDetail(member, stats: stats)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func providerBar(_ member: TeamStats.Member, top: Double) -> some View {
        ProviderSplitBar(providers: metric.barSegments(member.providers, total: member.totals), top: top, sort: sort)
    }

    @ViewBuilder
    private func memberDetail(_ member: TeamStats.Member, stats: TeamStats) -> some View {
        let providers = member.providers.filter { metric.value($0.totals) > 0 }
        let models = stats.models
            .compactMap { model -> (TeamStats.Model, UsageTotals)? in
                guard let mine = model.members.first(where: { $0.userID == member.userID }) else { return nil }
                return (model, mine.totals)
            }
            .filter { metric.value($0.1) > 0 }
            .sorted { metric.value($0.1) > metric.value($1.1) }
            .prefix(3)
        VStack(alignment: .leading, spacing: 4) {
            if let teamID = container.teams.selectedTeamID {
                ReactionButtons(teamID: teamID, member: member, compact: true)
                    .padding(.bottom, 2)
                if let projection = container.teamsSocial.projection(teamID: teamID, userID: member.userID), projection.spentSoFar > 0 {
                    ProjectionText(projection: projection).font(.caption)
                }
            }
            if providers.isEmpty {
                Text("No usage in this period.").font(.caption).foregroundStyle(.secondary)
            }
            // Cost/MTok already shows the member's rate on their row.
            if metric != .costPerMtok, let perMillion = TeamsFormat.perMillion(member.totals) {
                HStack {
                    Text("Efficiency").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(perMillion).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
            }
            ForEach(providers) { provider in
                detailRow(color: TotalSpendPalette.color(for: provider.provider), title: providerName(provider.provider), totals: provider.totals)
            }
            if !models.isEmpty {
                Text("Top Models")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(Array(models), id: \.0.id) { model, totals in
                    detailRow(color: TotalSpendPalette.color(for: model.provider), title: model.model, totals: totals)
                }
            }
        }
    }

    private func detailRow(color: Color, title: String, totals: UsageTotals) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(metric.format(totals))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func providerName(_ id: String) -> String {
        container.registry.providers.first { $0.id == id }?.displayName ?? id.capitalized
    }

    // MARK: - Error state

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(Theme.notice).multilineTextAlignment(.center)
            Button("Try Again") { Task { await load() } }.controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .cardSurface()
    }
}
