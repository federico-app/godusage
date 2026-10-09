import SwiftUI

/// One ⚡ per momentum level (1–3): a member spending fast right now. Nothing at level 0.
struct MomentumBolts: View {
    let momentum: TeamMomentum?

    var body: some View {
        if let level = momentum?.level, level > 0 {
            Text(String(repeating: "⚡", count: min(level, 3)))
                .font(.caption)
                .accessibilityLabel("Spending fast: level \(min(level, 3)) of 3")
        }
    }
}

/// The line under a member's bar: "+$12.40/h" (spent in the last hour) while they have momentum,
/// otherwise when they last synced, plus their version only when it is outdated. The member's
/// detail explains everything in full.
struct MemberStatusNote: View {
    let member: TeamStats.Member
    let momentum: TeamMomentum?
    let newestVersion: String?

    var body: some View {
        if let momentum, momentum.level > 0 {
            Text("+\(Formatters.currency(momentum.lastHourUSD))/h")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.notice)
                .lineLimit(1)
                .accessibilityLabel("\(Formatters.currency(momentum.lastHourUSD)) in the last hour")
        } else {
            TeamSyncNote(member: member, newestVersion: newestVersion)
        }
    }
}

/// The top of a member's detail: what every mark on their row means, in words. Their place and
/// movement, their spend in the last hour and why it earned ⚡, their crowns, who reacted, and when
/// and from which version their Macs last synced.
struct MemberDetailNotes: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let stats: TeamStats
    let range: StatsRange
    let teamID: String

    var body: some View {
        let social = container.teamsSocial
        let momentum = container.teams.momentumByTeam[teamID]?[member.userID]
        VStack(alignment: .leading, spacing: 3) {
            note(placeText)
            if let momentum, momentum.lastHourUSD > 0 {
                note(momentumText(momentum), emphasized: momentum.level > 0)
            }
            if social.kingOfTheDay(teamID: teamID)?.userID == member.userID {
                note("👑 Top spender today")
            }
            if let champion = social.lastMonthChampion(teamID: teamID), champion.userID == member.userID {
                note("🏆 \(champion.monthLabel) champion: top spender of the month")
            }
            ForEach(reactionLines(social.reactions(teamID: teamID, userID: member.userID)), id: \.self) { line in
                note(line)
            }
            note(syncText)
        }
    }

    private func note(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(emphasized ? AnyShapeStyle(Theme.notice) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "1st of 6 · up 2 places since yesterday".
    private var placeText: String {
        let place = "\(Self.ordinal(member.rank)) of \(stats.members.count)"
        if range == .year { return place }
        guard let change = member.rankChange else {
            return member.costUSD > 0 || member.tokens > 0 ? "\(place) · new: no usage \(range.previousLabel)" : place
        }
        if change == 0 { return "\(place) · same place as \(range.previousLabel)" }
        let places = abs(change) == 1 ? "1 place" : "\(abs(change)) places"
        return "\(place) · \(change > 0 ? "up" : "down") \(places) since \(range.previousLabel)"
    }

    /// "⚡⚡ $18.40 in the last hour: over $5, more than twice their usual hour ($3.10), the most in the team".
    private func momentumText(_ momentum: TeamMomentum) -> String {
        let spent = "\(Formatters.currency(momentum.lastHourUSD)) in the last hour"
        let reasons = (momentum.reasons ?? []).compactMap { reason -> String? in
            switch reason {
            case "fast": "over $5"
            case "self": momentum.typicalHourUSD.map { "more than twice their usual hour (\(Formatters.currency($0)))" }
                ?? "more than twice their usual hour"
            case "top": "the most in the team"
            default: nil
            }
        }
        guard momentum.level > 0 else { return spent }
        let bolts = String(repeating: "⚡", count: min(momentum.level, 3))
        return reasons.isEmpty ? "\(bolts) \(spent)" : "\(bolts) \(spent): \(reasons.joined(separator: ", "))"
    }

    /// "🔥 Lorenzo, You", one line per reaction someone gave today.
    private func reactionLines(_ reactions: MemberReactions) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: stats.members.map { ($0.userID, $0.displayName) })
        let me = container.teams.user?.id
        return TeamReaction.allCases.compactMap { reaction in
            let count = reactions.count(reaction)
            guard count > 0 else { return nil }
            let givers = (reactions.from?[reaction.rawValue] ?? []).map { $0 == me ? "You" : names[$0] ?? "a former member" }
            return givers.isEmpty ? "\(reaction.emoji) \(count) today" : "\(reaction.emoji) \(givers.joined(separator: ", "))"
        }
    }

    /// "Updated 3m ago · GodUsage v1.0.9", with a nudge when the team runs a newer version.
    private var syncText: String {
        let synced = TeamsFormat.syncNote(member.lastSyncAt, now: Date())?.text ?? "Not synced yet"
        guard let version = member.appVersion else { return synced }
        let newest = TeamsFormat.newestVersion(stats.members)
        let outdated = TeamsFormat.isOutdated(version, newest: newest)
        let suffix = outdated ? ", older than the team's newest (\(TeamsFormat.versionLabel(newest ?? "")))" : ""
        return "\(synced) · GodUsage \(TeamsFormat.versionLabel(version))\(suffix)"
    }

    private static func ordinal(_ rank: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: rank)) ?? "#\(rank)"
    }
}

extension TeamsFormat {
    /// The newest GodUsage version among the members' latest uploads.
    static func newestVersion(_ members: [TeamStats.Member]) -> String? {
        members.compactMap(\.appVersion).max { versionParts($0).lexicographicallyPrecedes(versionParts($1)) }
    }

    /// Whether `version` is older than `newest`, comparing the leading numbers ("1.0.9" < "1.0.10";
    /// a "-dev.642" suffix is ignored). False when either is unknown.
    static func isOutdated(_ version: String?, newest: String?) -> Bool {
        guard let version, let newest else { return false }
        return versionParts(version).lexicographicallyPrecedes(versionParts(newest))
    }

    private static func versionParts(_ version: String) -> [Int] {
        let numeric = version.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }
}
