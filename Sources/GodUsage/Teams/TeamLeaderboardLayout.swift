import Foundation

/// How a leaderboard card lays out its members: always in ranking order, each with a row style (full
/// while they spent something in the last hour, compact otherwise), the rank labels ("6=" for ties),
/// the header's summary, and which providers the legend names. Shared by the dashboard's Team section
/// and the Teams window.
struct TeamLeaderboardLayout: Equatable {
    /// How a member's row is drawn. The style never moves a member: the list stays in rank order.
    enum RowStyle: Equatable {
        /// Bar, live last hour and momentum: the member spent something in the last hour.
        case full
        /// Two short lines, no bar: nothing spent in the last hour.
        case compact
    }

    struct Row: Equatable, Identifiable {
        let member: TeamStats.Member
        let style: RowStyle
        var id: String { member.userID }
    }

    /// Every member, in the order given (ranking order), with its row style.
    let rows: [Row]
    /// "6" or "6=" by user id.
    let rankLabels: [String: String]
    /// How many members spent something in the last hour: the header's "N active now". They get
    /// the full row; when there are none, every member does.
    let activeCount: Int

    /// `members` must already be in ranking order (see `TeamMetric.ranked`).
    init(members: [TeamStats.Member], momentum: [String: TeamMomentum]) {
        let styles = members.map { Self.rowStyle(momentum[$0.userID]) }
        let active = styles.filter { $0 == .full }.count
        activeCount = active
        // Nobody spent anything in the last hour: everyone keeps the full row, so a quiet team keeps
        // its bars.
        rows = zip(members, styles).map { Row(member: $0, style: active == 0 ? .full : $1) }
        rankLabels = Self.rankLabels(members)
    }

    /// Full when the member spent something in the last hour (or has momentum), compact otherwise.
    static func rowStyle(_ momentum: TeamMomentum?) -> RowStyle {
        guard let momentum else { return .compact }
        return momentum.lastHourUSD > 0 || momentum.level > 0 ? .full : .compact
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
