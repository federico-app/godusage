import SwiftUI

/// 🔥 👏 🤡 for one member: tap to give or take back yours. Your own row shows the counts only.
struct ReactionButtons: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    let member: TeamStats.Member
    var compact = false

    var body: some View {
        let social = container.teamsSocial
        let reactions = social.reactions(teamID: teamID, userID: member.userID)
        let isMe = member.userID == container.teams.user?.id
        HStack(spacing: 4) {
            ForEach(TeamReaction.allCases, id: \.self) { reaction in
                let count = reactions.count(reaction)
                let mine = reactions.mine.contains(reaction)
                Button {
                    Task { await social.toggle(reaction, teamID: teamID, userID: member.userID) }
                } label: {
                    HStack(spacing: 2) {
                        Text(reaction.emoji)
                        if count > 0 { Text("\(count)").monospacedDigit() }
                    }
                    .font(compact ? .caption2 : .caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(mine ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                    )
                    .overlay(Capsule().strokeBorder(mine ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isMe)
                .accessibilityLabel("\(reaction.accessibilityName), \(count)")
                .accessibilityAddTraits(mine ? .isSelected : [])
            }
        }
    }
}

/// Only the reactions someone got today, e.g. "🔥2 👏1", for a ranking row.
struct ReactionCounts: View {
    let reactions: MemberReactions

    var body: some View {
        if reactions.total > 0 {
            HStack(spacing: 3) {
                ForEach(TeamReaction.allCases.filter { reactions.count($0) > 0 }, id: \.self) { reaction in
                    Text("\(reaction.emoji)\(reactions.count(reaction))").monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// 👑 for today's top spender, 🏆 for last month's champion.
struct MemberBadges: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    let userID: String

    var body: some View {
        let social = container.teamsSocial
        HStack(spacing: 2) {
            if social.kingOfTheDay(teamID: teamID)?.userID == userID {
                Text("👑")
                    .accessibilityLabel("Top spender today")
                    .hoverTooltip("Top spender today")
            }
            if let champion = social.lastMonthChampion(teamID: teamID), champion.userID == userID {
                Text("🏆")
                    .accessibilityLabel("\(champion.monthLabel) champion")
                    .hoverTooltip("\(champion.monthLabel) champion: top spender of the month")
            }
        }
        .font(.caption)
    }
}

/// "On pace for $412 in October · 26 days left".
struct ProjectionText: View {
    let projection: TeamProjection
    var prefix = "On pace for"

    var body: some View {
        Text("\(prefix) \(Formatters.currency(projection.projected)) in \(projection.monthName)")
            + Text(projection.daysLeft > 0 ? " · \(projection.daysLeft) days left" : "").foregroundStyle(.secondary)
    }
}

/// One challenge in a few words, for the popover: title, time left, leader.
struct ChallengeSummaryRow: View {
    let challenge: TeamChallenge
    let me: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: challenge.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(challenge.kind.title).font(.callout.weight(.medium))
                Text(leaderText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(challenge.finished ? "Ended" : challenge.daysLeftText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var leaderText: String {
        let people = challenge.finished ? challenge.winners : challenge.standings.filter { $0.rank == 1 }
        guard let first = people.first else { return challenge.finished ? "No winner" : "Nobody qualifies yet" }
        let name = first.userID == me ? "You" : first.displayName
        let value = challenge.kind.valueText(first.value)
        return challenge.finished ? "🏅 \(name) won · \(value)" : "Leading: \(name) · \(value)"
    }
}

/// The Teams window's challenges: start one, follow the standings, see the winners.
struct TeamChallengesSection: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    @State private var confirmingCancel: TeamChallenge?

    var body: some View {
        let social = container.teamsSocial
        let challenges = social.challenges(teamID: teamID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Challenges").font(.headline)
                    Text("Timed contests inside the team. Anyone can start one.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(ChallengeKind.allCases, id: \.self) { kind in
                        Menu(kind.title) {
                            ForEach([7, 14, 30], id: \.self) { days in
                                Button("\(days) Days") {
                                    Task { await social.createChallenge(teamID: teamID, kind: kind, days: days) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("New Challenge", systemImage: "flag.checkered")
                }
                .fixedSize()
                .disabled(social.isWorking)
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 0) {
                if challenges.isEmpty {
                    Text("No challenges yet. Start one: lowest spend, most models, most tokens, or best efficiency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(Array(challenges.enumerated()), id: \.element.id) { index, challenge in
                    if index > 0 { Divider() }
                    challengeDetail(challenge)
                }
                if let error = social.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Theme.notice).padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .task(id: teamID) { await social.loadChallenges(teamID: teamID) }
        .alert(item: $confirmingCancel) { challenge in
            Alert(
                title: Text("Cancel \(challenge.kind.title)?"),
                message: Text("The challenge and its standings are removed for everyone."),
                primaryButton: .destructive(Text("Cancel Challenge")) {
                    Task { await social.cancelChallenge(teamID: teamID, challengeID: challenge.id) }
                },
                secondaryButton: .cancel(Text("Keep"))
            )
        }
    }

    private func challengeDetail(_ challenge: TeamChallenge) -> some View {
        let me = container.teams.user?.id
        let canCancel = !challenge.finished && (challenge.createdBy == me || isOwner)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                ChallengeSummaryRow(challenge: challenge, me: me)
                if canCancel {
                    Button { confirmingCancel = challenge } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel Challenge")
                }
            }
            Text(challenge.kind.rule).font(.caption2).foregroundStyle(.secondary)
            ForEach(challenge.standings.prefix(5)) { standing in
                HStack(spacing: 6) {
                    Text("\(standing.rank)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 16, alignment: .trailing)
                    Text(standing.userID == me ? "You" : standing.displayName).font(.caption).lineLimit(1)
                    Spacer()
                    Text(challenge.kind.valueText(standing.value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var isOwner: Bool {
        container.teams.teams.first { $0.id == teamID }?.role == .owner
    }
}

/// The last twelve months' champions.
struct HallOfFameSection: View {
    @Environment(AppContainer.self) private var container
    let teamID: String

    var body: some View {
        let champions = container.teams.championsByTeam[teamID] ?? []
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Hall of Fame").font(.headline)
                Text("Each month's top spender. A month counts once it's over.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                if champions.isEmpty {
                    Text("The first champion is crowned when this month ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(Array(champions.enumerated()), id: \.element.id) { index, champion in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Text("🏆")
                        Text(champion.monthLabel).frame(width: 130, alignment: .leading)
                        Text(champion.displayName).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(Formatters.currency(champion.costUSD)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}
