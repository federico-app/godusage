import SwiftUI

/// A member's row, as on the Mac (`TeamLeaderboardMemberRow`): the rank with its movement under it,
/// the name with You and the gold marks, the spend on the right, the provider bar scaled to the top
/// member, then the status line (spend in the last hour, or the last sync) and the momentum bolts.
struct TeamMemberRow: View {
    static let rankColumnWidth: CGFloat = 28
    static let columnSpacing: CGFloat = 10
    static var contentInset: CGFloat { rankColumnWidth + columnSpacing }

    let member: TeamBoard.Member
    let rankLabel: String
    let isMe: Bool
    let top: Double
    let range: BoardRange
    let momentum: TeamMomentum?
    let isTopToday: Bool
    let champion: TeamChampion?

    var body: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: rankLabel)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(member.rank <= 3 ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                RankChangeBadge(change: member.rankChange, hasUsage: member.costUSD > 0 || member.tokens > 0, range: range)
            }
            .frame(width: Self.rankColumnWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: member.displayName)
                        .fontWeight(isMe ? .semibold : .regular)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if isMe { YouChip() }
                    badges
                    Spacer(minLength: 6)
                    Text(TeamsFormat.cost(member.costUSD))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .layoutPriority(2)
                }
                ProviderSplitBar(providers: member.providers, top: top)
                HStack(spacing: 6) {
                    statusNote
                    Spacer(minLength: 6)
                    MomentumBolts(level: momentum?.level ?? 0)
                }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        if isTopToday || champion != nil {
            HStack(spacing: 3) {
                if isTopToday {
                    Image(systemName: "crown.fill").accessibilityLabel(Text("Top spender today"))
                }
                if let champion {
                    Image(systemName: "trophy.fill").accessibilityLabel(Text("\(champion.monthLabel) champion: top spender of the month"))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(WeekLimitColors.gold)
            .fixedSize()
        }
    }

    /// A green dot and "+$12.40 last hour" while they spend, otherwise when they last synced.
    @ViewBuilder
    private var statusNote: some View {
        if let momentum, momentum.isActive {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                Text("+\(TeamsFormat.cost(momentum.lastHourUSD)) last hour", comment: "Spend in the last hour, under a member's bar.")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Active now: \(TeamsFormat.cost(momentum.lastHourUSD)) in the last hour"))
        } else if let note = TeamsFormat.syncNote(member.lastSyncAt) {
            Group {
                if note.stale {
                    Label(note.text, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } else {
                    Text(note.text)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
            .fixedSize()
    }
}

/// A member's spend split by provider, scaled against the top member so bars compare across rows.
struct ProviderSplitBar: View {
    let providers: [ProviderTotals]
    let top: Double

    var body: some View {
        GeometryReader { proxy in
            let segments = providers.filter { $0.costUSD > 0 }
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { provider in
                    Rectangle()
                        .fill(ProviderPalette.color(for: provider.provider))
                        .frame(width: top > 0 ? max(2, (proxy.size.width - gaps) * provider.costUSD / top) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 5)
        .background(.secondary.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// A member spending fast right now: a bolt and a three-step meter filled up to the level (1–3).
struct MomentumBolts: View {
    let level: Int

    var body: some View {
        if level > 0 {
            let filled = min(level, 3)
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(1...3, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 3, height: CGFloat(2 + 2 * step))
                            .opacity(step <= filled ? 1 : 0.25)
                    }
                }
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Spending fast: level \(filled) of 3"))
        }
    }
}

/// Movement since the previous period: ▲2 (gained two places), ▼1, or "New" for a member who had no
/// usage then.
struct RankChangeBadge: View {
    let change: Int?
    var hasUsage = true
    let range: BoardRange

    var body: some View {
        if let change {
            if change != 0 {
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
        } else if hasUsage {
            Text("New")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

extension TeamsFormat {
    struct SyncNote {
        var text: String
        var stale: Bool
    }

    /// The Mac's sync line: "Updated just now", "Updated 5m ago", "Updated 3h ago", then "Not synced
    /// for 13 days" (stale) once it is more than a day old.
    static func syncNote(_ lastSyncAt: String?, now: Date = Date()) -> SyncNote? {
        guard let date = instant(lastSyncAt) else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let hours = minutes / 60, days = minutes / (24 * 60)
        if minutes < 1 { return SyncNote(text: String(localized: "Updated just now"), stale: false) }
        if minutes < 60 { return SyncNote(text: String(localized: "Updated \(minutes)m ago", comment: "Minutes since a member's last sync."), stale: false) }
        if minutes <= 24 * 60 { return SyncNote(text: String(localized: "Updated \(hours)h ago", comment: "Hours since a member's last sync."), stale: false) }
        return SyncNote(text: String(localized: "Not synced for \(days) days"), stale: true)
    }
}
