import SwiftUI

/// The leaderboard card, as on the Mac's panel: "N active now" and the bar colors on top, then one
/// row per member in rank order (tap for their detail), then Advanced Stats.
struct TeamLeaderboardCard: View {
    var model: TeamsModel
    let team: TeamSummary
    let board: TeamBoard
    let range: BoardRange

    var body: some View {
        let momentum = model.momentum[team.id] ?? [:]
        let active = board.members.filter { momentum[$0.userID]?.isActive == true }.count
        let top = board.members.map(\.costUSD).max() ?? 0
        let labels = Self.rankLabels(board.members)
        let crown = model.topSpenderToday(teamID: team.id)
        let champion = model.lastMonthChampion(teamID: team.id)
        VStack(spacing: 0) {
            header(active: active)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ForEach(Array(board.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 14 + TeamMemberRow.contentInset) }
                let isMe = member.userID == model.session?.user.id
                NavigationLink(value: MemberRoute(member: member, range: range)) {
                    TeamMemberRow(
                        member: member, rankLabel: labels[member.userID] ?? "\(member.rank)", isMe: isMe, top: top, range: range,
                        momentum: momentum[member.userID], isTopToday: crown == member.userID,
                        champion: champion?.userID == member.userID ? champion : nil
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMe ? Color.accentColor.opacity(0.08) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            NavigationLink(value: AdvancedStatsRoute(teamID: team.id, teamName: team.name, range: range)) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary).frame(width: 20)
                    Text("Advanced Stats")
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .cardSurface()
    }

    private func header(active: Int) -> some View {
        let providers = legendProviders
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                activeText(active)
                Spacer(minLength: 6)
                legend(providers)
            }
            VStack(alignment: .leading, spacing: 4) {
                activeText(active)
                legend(providers)
            }
        }
    }

    @ViewBuilder
    private func activeText(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count) active now", comment: "Leaderboard header: members spending fast right now")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func legend(_ providers: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(ProviderPalette.color(for: provider)).frame(width: 8, height: 8)
                    Text(verbatim: TeamsFormat.providerName(provider)).lineLimit(1)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Bar colors: \(providers.map(TeamsFormat.providerName).formatted(.list(type: .and)))"))
    }

    /// The providers the bars draw, largest first, so the legend names only colors on screen.
    private var legendProviders: [String] {
        var totals: [String: Double] = [:]
        for member in board.members {
            for provider in member.providers { totals[provider.provider, default: 0] += provider.costUSD }
        }
        return totals.filter { $0.value > 0 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
    }

    /// The rank, with "=" when the member before or after shares it.
    static func rankLabels(_ members: [TeamBoard.Member]) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, member) in members.enumerated() {
            let tiedBefore = index > 0 && members[index - 1].rank == member.rank
            let tiedAfter = index + 1 < members.count && members[index + 1].rank == member.rank
            labels[member.userID] = tiedBefore || tiedAfter ? "\(member.rank)=" : "\(member.rank)"
        }
        return labels
    }
}
