import Foundation

/// How a leaderboard card lays out its members: the rank labels ("6=" for ties), who is active right
/// now and who folds into the compact Idle group, the header's summary, and which providers the
/// legend names. Shared by the dashboard's Team section and the Teams window.
struct TeamLeaderboardLayout: Equatable {
    /// Members with momentum (⚡ level above 0), in ranking order. All members when nobody is active.
    let active: [TeamStats.Member]
    /// Members without momentum, in ranking order; empty when nobody is active (no split then).
    let idle: [TeamStats.Member]
    /// "6" or "6=" by user id.
    let rankLabels: [String: String]
    /// How many members have momentum right now.
    let activeCount: Int

    /// `members` must already be in ranking order (see `TeamMetric.ranked`).
    init(members: [TeamStats.Member], momentum: [String: TeamMomentum]) {
        let isActive = { (member: TeamStats.Member) in (momentum[member.userID]?.level ?? 0) > 0 }
        let activeMembers = members.filter(isActive)
        activeCount = activeMembers.count
        if activeMembers.isEmpty {
            active = members
            idle = []
        } else {
            active = activeMembers
            idle = members.filter { !isActive($0) }
        }
        rankLabels = Self.rankLabels(members)
    }

    /// The rank, with "=" when the member before or after shares it.
    static func rankLabels(_ members: [TeamStats.Member]) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, member) in members.enumerated() {
            let tiedBefore = index > 0 && members[index - 1].rank == member.rank
            let tiedAfter = index + 1 < members.count && members[index + 1].rank == member.rank
            labels[member.userID] = tiedBefore || tiedAfter ? "\(member.rank)=" : "\(member.rank)"
        }
        return labels
    }

    func rankLabel(_ member: TeamStats.Member) -> String {
        rankLabels[member.userID] ?? "\(member.rank)"
    }

    /// The header's left side: "4 active now", or nil while nobody is active. The team total is
    /// already above the card, so the header leaves it out.
    static func activeSummary(activeCount: Int) -> String? {
        activeCount > 0 ? "\(activeCount) active now" : nil
    }

    /// The providers the ranking's bars draw (members and shared accounts), largest first, so the
    /// legend names only colors that are on screen.
    static func legendProviders(
        members: [TeamStats.Member], shared: [TeamStats.SharedAccount], metric: TeamMetric
    ) -> [String] {
        var totals: [String: Double] = [:]
        for member in members {
            for segment in metric.barSegments(member.providers, total: member.totals) {
                totals[segment.provider, default: 0] += segment.totals.value(for: metric.sort)
            }
        }
        for account in shared {
            totals[account.provider, default: 0] += metric.value(account.totals)
        }
        return totals.filter { $0.value > 0 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
    }
}
