import SwiftUI

/// One team's spend leaderboard for Today, 7 Days, or 30 Days.
struct TeamBoardView: View {
    var model: TeamsModel
    let team: TeamSummary
    @State private var range: BoardRange = .week

    var body: some View {
        List {
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
                        Text("\(TeamsFormat.cost(board.totals.costUSD)) · \(TeamsFormat.tokens(board.totals.tokens))")
                    }
                }
                Section("Leaderboard") {
                    ForEach(board.members) { member in
                        row(member, isMe: member.userID == model.session?.user.id)
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(team.name)
        .task(id: range) { await model.loadBoard(teamID: team.id, range: range) }
        .refreshable { await model.loadBoard(teamID: team.id, range: range) }
    }

    private func row(_ member: TeamBoard.Member, isMe: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(member.rank)")
                .font(.headline.monospacedDigit())
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(member.displayName) (You)" : member.displayName)
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
}
