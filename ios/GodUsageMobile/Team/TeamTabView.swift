import SwiftUI

/// The Team tab, laid out like the Team section of the Mac's panel: the team's name (a picker with
/// several teams) and refresh, the period, the team's spend and month-end projection, This Week's
/// Limit with Live Pace, and the leaderboard. Advanced Stats opens the charts, providers, and models.
struct TeamTabView: View {
    var model: TeamsModel
    @State private var range: BoardRange = .today
    @State private var isRefreshing = false

    /// The board reloads this often while the tab is on screen, like the Mac's open panel.
    private static let reloadInterval: Duration = .seconds(120)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.errorMessage { ErrorBanner(message: error) }
                    if let team = model.selectedTeam {
                        content(team)
                    } else if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ContentUnavailableView {
                            Label("No Team", systemImage: "person.3")
                        } description: {
                            Text("You're not in a team yet. Create or join one in GodUsage on your Mac.")
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Team")
            .toolbar { AccountMenu(model: model) }
            .refreshable { await reload() }
            .navigationDestination(for: MemberRoute.self) { route in
                TeamMemberView(member: route.member, range: route.range, isMe: route.member.userID == model.session?.user.id)
            }
            .navigationDestination(for: AdvancedStatsRoute.self) { route in
                TeamAdvancedStatsView(model: model, teamID: route.teamID, teamName: route.teamName, range: route.range)
            }
            .task(id: LoadKey(teamID: model.selectedTeam?.id, range: range)) { await keepLoaded() }
        }
    }

    private struct LoadKey: Hashable {
        var teamID: String?
        var range: BoardRange
    }

    private func keepLoaded() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: Self.reloadInterval)
        }
    }

    private func reload() async {
        guard let teamID = model.selectedTeam?.id else { return }
        async let board: Void = model.loadBoard(teamID: teamID, range: range)
        async let plans: Void = model.loadPlans(teamID: teamID)
        _ = await (board, plans)
    }

    @ViewBuilder
    private func content(_ team: TeamSummary) -> some View {
        header(team)
        Picker("Range", selection: $range) {
            ForEach(BoardRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if let board = model.board(teamID: team.id, range: range) {
            summary(board, teamID: team.id)
            if let plans = model.plans[team.id], !plans.weekly.isEmpty {
                TeamWeekLimitCard(model: model, teamID: team.id, plans: plans)
            }
            TeamLeaderboardCard(model: model, team: team, board: board, range: range)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private func header(_ team: TeamSummary) -> some View {
        HStack(spacing: 8) {
            if model.teams.count > 1 {
                Menu {
                    Picker("Team", selection: Binding(get: { team.id }, set: { model.selectedTeamID = $0 })) {
                        ForEach(model.teams) { Text(verbatim: $0.name).tag($0.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: team.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
            } else {
                Text(verbatim: team.name).font(.title3.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Group {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            await reload()
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Refresh Team"))
                }
            }
            .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 4)
    }

    /// "$13.59 team spend", then "Team on pace for $2,881.24 in November · 12 days left".
    private func summary(_ board: TeamBoard, teamID: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TeamsFormat.cost(board.totals.costUSD))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text("team spend", comment: "Caption under the team total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let projection = model.projection(teamID: teamID) {
                let amount = TeamsFormat.cost(projection.projected)
                let month = projection.monthName
                let head = Text("Team on pace for \(amount) in \(month)", comment: "The team's month-end spend projection: amount, month.")
                Group {
                    if projection.daysLeft > 0 {
                        Text("\(head)\(Text(" · \(projection.daysLeft) days left").foregroundStyle(.secondary))")
                    } else {
                        head
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct MemberRoute: Hashable {
    var member: TeamBoard.Member
    var range: BoardRange
}

struct AdvancedStatsRoute: Hashable {
    var teamID: String
    var teamName: String
    var range: BoardRange
}
