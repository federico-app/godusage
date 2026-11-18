import Foundation

/// The members in ranking order, rank labels ("6=" for ties), header summary, and provider legend.
/// Every member keeps their provider bar regardless of activity. Shared by the dashboard and Teams window.
struct TeamLeaderboardLayout: Equatable {
    struct Row: Equatable, Identifiable {
        let member: TeamStats.Member
        var id: String { member.userID }
    }

    /// Every member, in the order given (ranking order).
    let rows: [Row]
    /// "6" or "6=" by user id.
    let rankLabels: [String: String]
    /// How many members spent something in the last hour: the header's "N active now".
    let activeCount: Int

    /// `members` must already be in ranking order (see `TeamMetric.ranked`).
    init(members: [TeamStats.Member], momentum: [String: TeamMomentum]) {
        activeCount = members.filter { Self.isActive(momentum[$0.userID]) }.count
        rows = members.map { Row(member: $0) }
        rankLabels = Self.rankLabels(members)
    }

    /// Activity affects the summary and status note, never whether the row shows a bar.
    static func isActive(_ momentum: TeamMomentum?) -> Bool {
        guard let momentum else { return false }
        return momentum.lastHourUSD > 0 || momentum.level > 0
    }

    /// The first `limit` rows in rank order: the popover's Members Shown collapse.
    func visibleRows(limit: Int) -> [Row] {
        Array(rows.prefix(max(0, limit)))
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
        activeCount > 0 ? String(localized: "\(activeCount) active now", comment: "Leaderboard header: members spending fast right now") : nil
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
