import SwiftUI

/// The dashboard's Team section, under Total Spend once you're signed in and in a team: the
/// selected team's ranking at a glance, with each member's split by provider. Click a member for their
/// providers and top models. Advanced Stats opens the Teams window with the full charts.
struct TeamDashboardSection: View {
    @Environment(AppContainer.self) private var container

    /// The Total Spend card's period switcher drives this section too (Today, Yesterday, 7 Days, 30 Days).
    @AppStorage("godusage.totalSpend.period") private var totalSpendPeriod = TotalSpendPeriod.today.rawValue
    /// The Total Spend card's metric menu drives this section too (Cost, Cost/MTok, Tokens).
    @AppStorage("godusage.totalSpend.metric") private var totalSpendMetric = TotalSpendMetric.cost.rawValue
    /// The popover's tree survives closing, so reloads key off visibility, not appearance.
    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @AppStorage(TeamDashboardPreferences.membersShownKey) private var membersShown = TeamMembersShown.default.rawValue
    @AppStorage(TeamDashboardPreferences.showProjectionKey) private var showProjection = true
    @AppStorage(TeamDashboardPreferences.showChallengesKey) private var showChallenges = true
    @AppStorage(TeamDashboardPreferences.showWeekStripKey) private var showWeekStrip = true
    @AppStorage(TeamDashboardPreferences.showLivePaceKey) private var showLivePace = true
    @State private var expandedMemberID: String?
    /// The caret under the first members unfolds the rest of the ranking.
    @State private var showsAllMembers = false
    @State private var isLoading = false
    /// The refresh button: this Mac's upload, then the board.
    @State private var isRefreshing = false

    private let density = DensitySetting.compact

    private var metric: TeamMetric { TeamMetric(TotalSpendMetric(rawValue: totalSpendMetric) ?? .cost) }
    private var sort: StatsSort { metric.sort }

    private var period: TotalSpendPeriod { TotalSpendPeriod(rawValue: totalSpendPeriod) ?? .today }
    /// Yesterday is the server's one-day range ending yesterday.
    private var range: StatsRange {
        switch period {
        case .today, .yesterday: .today
        case .last7: .week
        case .last30: .month
        }
    }
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
        // Today's leader (👑) and the month-to-date projection come with the board in one request.
        let extras = TeamsStore.extraBoards(range: range, sort: sort, endingOn: endingOn)
        await teams.loadStats(teamID: teamID, range: range, sort: sort, endingOn: endingOn, include: extras)
        isLoading = false
        if endingOn != nil {
            // A past period's board: today's extras need their own request.
            await teams.loadStats(teamID: teamID, range: .today, sort: .cost)
            await teams.loadStats(teamID: teamID, range: .monthToDate, sort: .cost)
        }
        await container.teamsSocial.loadChallenges(teamID: teamID)
        // Today's budget moves with use; the server recomputes the report after every new quota
        // reading. Your plans in your other teams join the strip; those reload at the background pace,
        // or every few minutes with Live Pace on.
        if showWeekStrip {
            await container.teamPlans.load(teamID: teamID)
            await container.teamPlans.loadIfStale(
                teamIDs: teams.teams.map(\.id).filter { $0 != teamID },
                maxAge: showLivePace ? TeamPlansStore.livePaceMaxAge : TeamPlansStore.backgroundMaxAge
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        let teams = container.teams
        controls
        if let stats {
            summary(stats)
            if showWeekStrip {
                TeamWeekStripCard(
                    plans: weekStripPlans, selectedTeamID: teams.selectedTeamID, teamName: teamName, today: teams.localToday()
                )
            }
            ranking(stats)
            if showChallenges { challengesCard }
        } else if let error = teams.statsError {
            errorCard(error)
        } else {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 24)
        }
        if stats != nil, let error = teams.statsError {
            Text(error).font(.caption).foregroundStyle(Theme.notice)
        } else if stats != nil, teams.statsPaused {
            Text(TeamsStore.statsPausedMessage).font(.caption).foregroundStyle(.secondary)
        }
        // Otherwise only Settings → Teams shows it, and the board just says "Not synced".
        if let error = teams.uploadError {
            Text("This Mac’s usage isn’t shared: \(error)").font(.caption).foregroundStyle(Theme.notice)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            teamPicker
            Spacer(minLength: 4)
            // A 28pt target around a 14pt glyph; the spinner takes the same slot, so nothing shifts.
            Group {
                if isLoading || isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Refresh Team")
                }
            }
            .frame(width: 28, height: 28)
            .padding(-4)
        }
    }

    /// Sends this Mac's usage now, then reloads the board, like the Teams window's refresh.
    private func refresh() async {
        isRefreshing = true
        await container.teams.uploadNow()
        await load()
        isRefreshing = false
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

    /// The selected team's plans, plus the plans that cover you in your other teams.
    private var weekStripPlans: [TeamPlanEntry] {
        let teams = container.teams
        return container.teamPlans.yourPlans(selectedTeamID: teams.selectedTeamID, teamIDs: teams.teams.map(\.id))
    }

    private func teamName(_ teamID: String) -> String? {
        container.teams.teams.first { $0.id == teamID }?.name
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
            if showProjection, let teamID = container.teams.selectedTeamID, let projection = container.teamsSocial.projection(teamID: teamID) {
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

    /// Active members get the full row, then the shared accounts, then the Idle group. The caret
    /// folds the list to the first members Customize → Team shows, counting active ones first.
    private func ranking(_ stats: TeamStats) -> some View {
        let top = stats.rankingTop(for: metric)
        let ranked = metric.ranked(stats.members)
        let momentum = container.teams.selectedTeamID.flatMap { container.teams.momentumByTeam[$0] } ?? [:]
        let layout = TeamLeaderboardLayout(members: ranked, momentum: momentum)
        let shared = stats.sharedAccounts(for: metric)
        let collapsedCount = (TeamMembersShown(rawValue: membersShown) ?? .default).visibleCount(of: ranked.count)
        let isCollapsible = collapsedCount < ranked.count
        let limit = isCollapsible && !showsAllMembers ? collapsedCount : ranked.count
        let visibleActive = Array(layout.active.prefix(limit))
        let visibleIdle = Array(layout.idle.prefix(max(0, limit - layout.active.count)))
        let header = TeamLeaderboardHeader(
            activeSummary: TeamLeaderboardLayout.activeSummary(activeCount: layout.activeCount),
            providers: TeamLeaderboardLayout.legendProviders(members: ranked, shared: shared, metric: metric),
            providerName: providerName
        )
        return VStack(spacing: 0) {
            if !header.isEmpty {
                header
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            ForEach(Array(visibleActive.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 12 + TeamLeaderboardRowStyle.contentInset) }
                memberRow(member, layout: layout, top: top, stats: stats, momentum: momentum[member.userID])
            }
            ForEach(shared) { account in
                Divider().padding(.leading, 12)
                TeamSharedAccountRow(account: account, stats: stats, metric: metric, top: top, providerName: providerName)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            if !visibleIdle.isEmpty {
                Divider()
                idleGroup(visibleIdle, total: layout.idle.count, layout: layout, stats: stats)
            }
            if isCollapsible {
                Divider()
                membersToggle(hiddenCount: ranked.count - collapsedCount)
            }
            Divider()
            advancedStatsRow
        }
        .cardSurface()
    }

    private func idleGroup(_ members: [TeamStats.Member], total: Int, layout: TeamLeaderboardLayout, stats: TeamStats) -> some View {
        let newest = TeamsFormat.newestVersion(stats.members)
        return VStack(alignment: .leading, spacing: 0) {
            TeamLeaderboardIdleHeader(count: total)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 3)
            ForEach(members) { member in
                let isExpanded = expandedMemberID == member.userID
                let isMe = member.userID == container.teams.user?.id
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(Motion.spring) { expandedMemberID = isExpanded ? nil : member.userID }
                    } label: {
                        TeamLeaderboardIdleRow(
                            member: member, rankLabel: layout.rankLabel(member), isMe: isMe, metric: metric,
<<<<<<< HEAD
                            newestVersion: newest, teamID: container.teams.selectedTeamID, isExpanded: isExpanded
=======
                            newestVersion: newest, teamID: container.teams.selectedTeamID
>>>>>>> origin/main
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isExpanded {
                        TeamMemberDetail(
                            member: member, stats: stats, metric: metric, range: range,
                            teamID: container.teams.selectedTeamID, providerName: providerName
                        )
                        .padding(.leading, TeamLeaderboardRowStyle.contentInset)
                        .padding(.bottom, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isMe ? TeamLeaderboardRowStyle.youTint : .clear)
            }
        }
        .padding(.bottom, 4)
        .background(TeamLeaderboardRowStyle.idleBackground)
    }

    /// The centered caret under the ranking, like a provider card's: unfolds or folds the members past
    /// the ones Customize → Team shows.
    private func membersToggle(hiddenCount: Int) -> some View {
        Button {
            withAnimation(Motion.spring) { showsAllMembers.toggle() }
        } label: {
            HStack(spacing: 4) {
                if !showsAllMembers {
                    Text("\(hiddenCount) More").font(.caption)
                }
                Image(systemName: showsAllMembers ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsAllMembers ? "Show fewer members" : "Show \(hiddenCount) more members")
    }

    /// Opens the Teams window: every range, charts, models, and the two-member comparison.
    private var advancedStatsRow: some View {
        Button { TeamsWindowLink.open(teamID: container.teams.selectedTeamID) } label: {
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

    private func memberRow(
        _ member: TeamStats.Member, layout: TeamLeaderboardLayout, top: Double, stats: TeamStats, momentum: TeamMomentum?
    ) -> some View {
        let isExpanded = expandedMemberID == member.userID
        let isMe = member.userID == container.teams.user?.id
        let teamID = container.teams.selectedTeamID
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spring) { expandedMemberID = isExpanded ? nil : member.userID }
            } label: {
                TeamLeaderboardMemberRow(
                    member: member, rankLabel: layout.rankLabel(member), isMe: isMe, top: top, metric: metric,
<<<<<<< HEAD
                    range: range, momentum: momentum, newestVersion: TeamsFormat.newestVersion(stats.members), teamID: teamID,
                    isExpanded: isExpanded
=======
                    range: range, momentum: momentum, newestVersion: TeamsFormat.newestVersion(stats.members), teamID: teamID
>>>>>>> origin/main
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                TeamMemberDetail(member: member, stats: stats, metric: metric, range: range, teamID: teamID, providerName: providerName)
                    .padding(.leading, TeamLeaderboardRowStyle.contentInset)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isMe ? TeamLeaderboardRowStyle.youTint : .clear)
    }

    private func providerName(_ id: String) -> String {
        container.registry.teamProviderName(id)
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
