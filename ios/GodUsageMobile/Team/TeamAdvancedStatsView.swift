import Charts
import SwiftUI

/// Advanced Stats for one team and period: the team's total spend and tokens, a chart of spend per
/// day by provider, and the spend per provider and per model.
struct TeamAdvancedStatsView: View {
    var model: TeamsModel
    let teamID: String
    let teamName: String
    let range: BoardRange

    var body: some View {
        List {
            if let board = model.board(teamID: teamID, range: range) {
                Section {
                    LabeledContent("Team Total") {
                        Text(verbatim: "\(TeamsFormat.cost(board.totals.costUSD)) · \(TeamsFormat.tokens(board.totals.tokens))")
                    }
                    if board.daily.count > 1, board.daily.contains(where: { !$0.providers.isEmpty }) {
                        TeamDailyChart(days: board.daily)
                    }
                } header: {
                    Text(range.title)
                }
                if !board.providers.isEmpty {
                    Section("Providers") {
                        ForEach(board.providers) { provider in
                            LabeledContent {
                                Text(verbatim: "\(TeamsFormat.cost(provider.costUSD)) · \(TeamsFormat.tokens(provider.tokens))")
                            } label: {
                                Label {
                                    Text(verbatim: TeamsFormat.providerName(provider.provider))
                                } icon: {
                                    Circle().fill(ProviderPalette.color(for: provider.provider)).frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }
                if !board.models.isEmpty {
                    Section("Models") {
                        ForEach(board.models) { modelRow($0) }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Advanced Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadBoard(teamID: teamID, range: range) }
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

/// The team's spend per day in the period, stacked by provider in the providers' colors.
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
            return day.providers.map { Point(date: date, provider: $0.provider, costUSD: $0.costUSD) }
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.costUSD))
                .foregroundStyle(ProviderPalette.color(for: point.provider))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 110)
        .padding(.vertical, 4)
    }
}
