import SwiftUI

/// The pieces of a leaderboard card, shared by the dashboard's Team section and the Teams window:
/// the header (team total, who is active, provider legend), the full member row, the Idle group's
/// one-line row, and the member's detail.
enum TeamLeaderboardRowStyle {
    /// The rank and its movement sit in this column; the shared-account icon too.
    static let rankColumnWidth: CGFloat = 26
    static let columnSpacing: CGFloat = 10
    /// The detail and the status line start under the name.
    static var contentInset: CGFloat { rankColumnWidth + columnSpacing }
    /// Your own row's background, besides the You chip.
    static let youTint = Color.accentColor.opacity(0.08)
    /// The Idle group's slightly darker band.
    static let idleBackground = Color.primary.opacity(0.03)
}

/// How a row shows reactions: tappable buttons (Teams window) or today's counts (dashboard, where a
/// click opens the member's detail with the buttons).
enum TeamReactionsStyle {
    case buttons
    case counts
}

/// "4 active now" on the left (nothing while nobody is active), the providers the bars use on the
/// right (or below, when they don't fit on one line). The team total is above the card already.
struct TeamLeaderboardHeader: View {
    /// From `TeamLeaderboardLayout.activeSummary`.
    let activeSummary: String?
    let providers: [String]
    let providerName: (String) -> String

    /// Nothing to show: callers leave the header and its divider out.
    var isEmpty: Bool { activeSummary == nil && providers.isEmpty }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                summary
                Spacer(minLength: 6)
                legend
            }
            VStack(alignment: .leading, spacing: 4) {
                summary
                legend
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let activeSummary {
            Text(activeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TotalSpendPalette.color(for: provider))
                        .frame(width: 8, height: 8)
                    Text(providerName(provider)).lineLimit(1)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bar colors: \(providers.map(providerName).joined(separator: ", "))")
    }
}

/// The small "You" capsule after your name.
struct YouChip: View {
    var body: some View {
        Text("You")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.12), in: Capsule())
            // Never compress: a long name truncates instead of the chip wrapping one letter per line.
            .fixedSize()
    }
}

/// A member's full row: rank with its movement under it, the name with You and the gold marks, the
/// value alone on the right, the provider bar, then the status line (live last hour or last sync on
/// the left; momentum and reactions on the right, never cut off).
struct TeamLeaderboardMemberRow: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let rankLabel: String
    let isMe: Bool
    let top: Double
    let metric: TeamMetric
    let range: StatsRange
    let momentum: TeamMomentum?
    let newestVersion: String?
    let teamID: String?
    var reactions: TeamReactionsStyle = .counts
    var valueFont: Font = .callout
    var barHeight: CGFloat = 5
<<<<<<< HEAD
    var isExpanded = false
=======
>>>>>>> origin/main

    var body: some View {
        HStack(alignment: .top, spacing: TeamLeaderboardRowStyle.columnSpacing) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(rankLabel)
                    .font(valueFont.monospacedDigit().weight(.semibold))
                    .foregroundStyle(member.rank <= 3 ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Movement compares server ranks, which Cost/MTok re-ranks.
                if metric != .costPerMtok {
                    RankChangeBadge(member: member, range: range, sort: metric.sort)
                }
            }
            .frame(width: TeamLeaderboardRowStyle.rankColumnWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
<<<<<<< HEAD
                if isExpanded {
                    TeamMemberExpandedHeader(member: member, isMe: isMe, value: metric.format(member.totals), teamID: teamID, valueFont: valueFont)
                } else {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .fontWeight(isMe ? .semibold : .regular)
                            // Names wrap rather than truncate: the full name matters more than one line.
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        if isMe { YouChip() }
                        if let teamID { MemberBadges(teamID: teamID, userID: member.userID) }
                        Spacer(minLength: 6)
                        Text(metric.format(member.totals))
                            .font(valueFont.monospacedDigit().weight(.semibold))
                            .layoutPriority(2)
                    }
                }
                ProviderSplitBar(providers: metric.barSegments(member.providers, total: member.totals), top: top, sort: metric.sort, height: barHeight)
                if !isExpanded {
                    HStack(spacing: 6) {
                        MemberStatusNote(member: member, momentum: momentum, newestVersion: newestVersion)
                        Spacer(minLength: 6)
                        HStack(spacing: 6) {
                            MomentumBolts(momentum: momentum)
                            reactionsView
                        }
                        .fixedSize()
                    }
=======
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .fontWeight(isMe ? .semibold : .regular)
                        // Names wrap rather than truncate: the full name matters more than one line.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if isMe { YouChip() }
                    if let teamID { MemberBadges(teamID: teamID, userID: member.userID) }
                    Spacer(minLength: 6)
                    Text(metric.format(member.totals))
                        .font(valueFont.monospacedDigit().weight(.semibold))
                        .layoutPriority(2)
                }
                ProviderSplitBar(providers: metric.barSegments(member.providers, total: member.totals), top: top, sort: metric.sort, height: barHeight)
                HStack(spacing: 6) {
                    MemberStatusNote(member: member, momentum: momentum, newestVersion: newestVersion)
                    Spacer(minLength: 6)
                    HStack(spacing: 6) {
                        MomentumBolts(momentum: momentum)
                        reactionsView
                    }
                    .fixedSize()
>>>>>>> origin/main
                }
            }
        }
    }

    @ViewBuilder
    private var reactionsView: some View {
        if let teamID {
            switch reactions {
            case .buttons: ReactionButtons(teamID: teamID, member: member, compact: true)
            case .counts: ReactionCounts(reactions: container.teamsSocial.reactions(teamID: teamID, userID: member.userID))
            }
        }
    }
}

/// One line in the Idle group: rank, name, when they last synced, an outdated version, reactions,
/// and the value. No bar: nobody here is spending right now.
struct TeamLeaderboardIdleRow: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let rankLabel: String
    let isMe: Bool
    let metric: TeamMetric
    let newestVersion: String?
    let teamID: String?
    var reactions: TeamReactionsStyle = .counts
    var now = Date()
<<<<<<< HEAD
    /// Expanded, the line becomes the name with the value, then the chips; the detail says the rest.
    var isExpanded = false

    var body: some View {
        HStack(alignment: isExpanded ? .firstTextBaseline : .center, spacing: TeamLeaderboardRowStyle.columnSpacing) {
=======

    var body: some View {
        HStack(spacing: TeamLeaderboardRowStyle.columnSpacing) {
>>>>>>> origin/main
            Text(rankLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: TeamLeaderboardRowStyle.rankColumnWidth, alignment: .trailing)
<<<<<<< HEAD
            if isExpanded {
                TeamMemberExpandedHeader(member: member, isMe: isMe, value: metric.format(member.totals), teamID: teamID)
            } else {
                line
            }
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            Text(member.displayName)
                .font(.callout)
                .fontWeight(isMe ? .semibold : .regular)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if isMe { YouChip() }
            if let teamID { MemberBadges(teamID: teamID, userID: member.userID) }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                OutdatedVersionChip(version: member.appVersion, newestVersion: newestVersion)
                syncAge
                reactionsView
                Text(metric.format(member.totals))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(metric.value(member.totals) > 0 ? .primary : .secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .fixedSize()
=======
            HStack(spacing: 6) {
                Text(member.displayName)
                    .font(.callout)
                    .fontWeight(isMe ? .semibold : .regular)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if isMe { YouChip() }
                if let teamID { MemberBadges(teamID: teamID, userID: member.userID) }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    OutdatedVersionChip(version: member.appVersion, newestVersion: newestVersion)
                    syncAge
                    reactionsView
                    Text(metric.format(member.totals))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(metric.value(member.totals) > 0 ? .primary : .secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .fixedSize()
            }
>>>>>>> origin/main
        }
    }

    @ViewBuilder
    private var syncAge: some View {
        if let age = TeamsFormat.syncAge(member.lastSyncAt, now: now) {
            Group {
                if age.stale {
                    Label(age.text, systemImage: "exclamationmark.arrow.triangle.2.circlepath").labelStyle(.titleAndIcon)
                } else {
                    Text(age.text)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Last synced \(age.text)")
        }
    }

    @ViewBuilder
    private var reactionsView: some View {
        if let teamID {
            switch reactions {
            case .buttons: ReactionButtons(teamID: teamID, member: member, compact: true)
            case .counts: ReactionCounts(reactions: container.teamsSocial.reactions(teamID: teamID, userID: member.userID))
            }
        }
    }
}

/// "Idle · 3" and a hairline: the start of the group of members not spending right now.
struct TeamLeaderboardIdleHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("Idle · \(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(.separator).frame(height: 0.5)
        }
        .accessibilityAddTraits(.isHeader)
    }
}
<<<<<<< HEAD
=======

/// What opens under a member on the dashboard: their row in words (`MemberDetailNotes`), the
/// reaction buttons, their projection and efficiency, then their providers and top models.
struct TeamMemberDetail: View {
    @Environment(AppContainer.self) private var container
    let member: TeamStats.Member
    let stats: TeamStats
    let metric: TeamMetric
    let range: StatsRange
    let teamID: String?
    let providerName: (String) -> String

    var body: some View {
        let providers = member.providers.filter { metric.value($0.totals) > 0 }
        let models = stats.models
            .compactMap { model -> (TeamStats.Model, UsageTotals)? in
                guard let mine = model.members.first(where: { $0.userID == member.userID }) else { return nil }
                return (model, mine.totals)
            }
            .filter { metric.value($0.1) > 0 }
            .sorted { metric.value($0.1) > metric.value($1.1) }
            .prefix(3)
        VStack(alignment: .leading, spacing: 4) {
            if let teamID {
                MemberDetailNotes(member: member, stats: stats, range: range, teamID: teamID)
                    .padding(.bottom, 4)
                ReactionButtons(teamID: teamID, member: member, compact: true)
                    .padding(.bottom, 2)
                if let projection = container.teamsSocial.projection(teamID: teamID, userID: member.userID), projection.spentSoFar > 0 {
                    ProjectionText(projection: projection).font(.caption)
                }
            }
            if providers.isEmpty {
                Text("No usage in this period.").font(.caption).foregroundStyle(.secondary)
            }
            // Cost/MTok already shows the member's rate on their row.
            if metric != .costPerMtok, let perMillion = TeamsFormat.perMillion(member.totals) {
                HStack {
                    Text("Efficiency").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(perMillion).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
            }
            ForEach(providers) { provider in
                detailRow(color: TotalSpendPalette.color(for: provider.provider), title: providerName(provider.provider), totals: provider.totals)
            }
            if !models.isEmpty {
                Text("Top Models")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(Array(models), id: \.0.id) { model, totals in
                    detailRow(color: TotalSpendPalette.color(for: model.provider), title: model.model, totals: totals)
                }
            }
        }
    }

    private func detailRow(color: Color, title: String, totals: UsageTotals) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(metric.format(totals))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
>>>>>>> origin/main
