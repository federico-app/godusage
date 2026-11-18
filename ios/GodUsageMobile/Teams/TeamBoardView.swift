import Charts
import SwiftUI

/// One team: This Week's Limit from the team's plans, then for Today, 7 Days, or 30 Days the team's
/// total and spend per day, the leaderboard (tap a member for their providers), and the spend per
/// provider and per model.
struct TeamBoardView: View {
    var model: TeamsModel
    let team: TeamSummary
    @State private var range: BoardRange = .week

    var body: some View {
        List {
            if let plans = model.plans[team.id], !plans.weekly.isEmpty {
                TeamWeekLimitSection(plans: plans)
            }
            Section {
                Picker("Range", selection: $range) {
                    ForEach(BoardRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let board = model.board(teamID: team.id, range: range) {
                Section {
                    LabeledContent("Team Total") {
                        Text(verbatim: "\(TeamsFormat.cost(board.totals.costUSD)) · \(TeamsFormat.tokens(board.totals.tokens))")
                    }
                    if board.daily.count > 1, board.daily.contains(where: { !$0.providers.isEmpty }) {
                        TeamDailyChart(days: board.daily)
                    }
                }
                Section("Leaderboard") {
                    ForEach(board.members) { member in
                        let isMe = member.userID == model.session?.user.id
                        NavigationLink {
                            TeamMemberView(member: member, range: range, isMe: isMe)
                        } label: {
                            row(member, isMe: isMe)
                        }
                    }
                }
                if !board.providers.isEmpty {
                    Section("Providers") {
                        ForEach(board.providers) { provider in
                            LabeledContent(TeamsFormat.providerName(provider.provider)) {
                                Text(verbatim: "\(TeamsFormat.cost(provider.costUSD)) · \(TeamsFormat.tokens(provider.tokens))")
                            }
                        }
                    }
                }
                if !board.models.isEmpty {
                    Section("Models") {
                        ForEach(board.models) { model in
                            modelRow(model)
                        }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(team.name)
        .task(id: range) { await model.loadBoard(teamID: team.id, range: range) }
        .task { await model.loadPlans(teamID: team.id) }
        .refreshable {
            async let board: Void = model.loadBoard(teamID: team.id, range: range)
            async let plans: Void = model.loadPlans(teamID: team.id)
            _ = await (board, plans)
        }
    }

    private func row(_ member: TeamBoard.Member, isMe: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(verbatim: "\(member.rank)")
                    .font(.headline.monospacedDigit())
                RankChangeBadge(change: member.rankChange, range: range)
            }
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if isMe {
                        Text("\(member.displayName) (You)", comment: "The signed-in user's own row in the leaderboard")
                    } else {
                        Text(verbatim: member.displayName)
                    }
                }
                .fontWeight(isMe ? .semibold : .regular)
                if let age = TeamsFormat.syncAge(member.lastSyncAt) {
                    Text(age).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(TeamsFormat.cost(member.costUSD)).monospacedDigit()
                Text(TeamsFormat.tokens(member.tokens)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func modelRow(_ model: TeamBoard.Model) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.model)
                Text(TeamsFormat.providerName(model.provider)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(TeamsFormat.cost(model.costUSD)).monospacedDigit()
                Text(TeamsFormat.tokens(model.tokens)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Movement since the previous period: ▲2 (gained two places) or ▼1. Nothing for a member who had no
/// usage then, or who kept their place.
struct RankChangeBadge: View {
    let change: Int?
    let range: BoardRange

    var body: some View {
        if let change, change != 0 {
            HStack(spacing: 1) {
                Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 7))
                Text(verbatim: "\(abs(change))")
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(change > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(range.movement(change))
        }
    }
}

/// The team's spend per day in the period, stacked by provider.
private struct TeamDailyChart: View {
    struct Point: Identifiable {
        var date: Date
        var provider: String
        var costUSD: Double
        var id: String { "\(date.timeIntervalSince1970)/\(provider)" }
    }

    let days: [TeamBoard.Day]

    private var points: [Point] {
        days.flatMap { day -> [Point] in
            guard let date = TeamsFormat.day(day.day) else { return [] }
            return day.providers.map { Point(date: date, provider: TeamsFormat.providerName($0.provider), costUSD: $0.costUSD) }
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.costUSD))
                .foregroundStyle(by: .value("Provider", point.provider))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 110)
        .padding(.vertical, 4)
    }
}
