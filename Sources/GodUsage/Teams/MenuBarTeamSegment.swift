import Foundation

/// The menu bar's team segment: rank, its movement since yesterday, and today's spend on top; your
/// pace on your team plan (or how old the data is) underneath, else that top line alone. Pure, so it is unit-tested; `StatusItemImageUpdater` feeds it
/// from `TeamsStore` and `TeamPlansStore`.
enum MenuBarTeamSegment {
    /// Past this age the bottom line says how old the team data is instead of a live figure.
    static let staleAfter: TimeInterval = 3600

    /// Your standing in the selected team, from today's spend board.
    struct Standing: Equatable {
        var rank: Int
        /// Places gained (positive) or lost since yesterday; nil without yesterday's board.
        var rankChange: Int?
        var spendUSD: Double
        /// "30%", nil while the team has spent nothing today. Only in the tooltip and VoiceOver label.
        var share: String?
        /// When your usage last reached the server.
        var syncedAt: Date?
    }

    /// "#2" + "▲1" (green) or "▼1" (dimmed) + " · $37".
    static func topLine(_ standing: Standing) -> [MenuBarSpan] {
        var spans = [MenuBarSpan("#\(standing.rank)")]
        if let change = standing.rankChange, change != 0 {
            spans.append(change > 0 ? MenuBarSpan("▲\(change)", .positive) : MenuBarSpan("▼\(-change)", .dim))
        }
        spans.append(MenuBarSpan(" · \(wholeDollars(standing.spendUSD))"))
        return spans
    }

    /// The bottom line: "Upd 2h" when the data is stale, else the most urgent plan's pace. Nil
    /// otherwise: the segment is then the top line alone, centered like a single value.
    static func bottomLine(standing: Standing, paces: [LivePace], now: Date) -> [MenuBarSpan]? {
        if let syncedAt = standing.syncedAt, now.timeIntervalSince(syncedAt) > staleAfter {
            let age = age(now.timeIntervalSince(syncedAt))
            return [MenuBarSpan(String(localized: "Upd \(age)", comment: "Menu bar team segment: the team data was last updated this long ago, e.g. Upd 2h. Keep it very short."), .dim)]
        }
        return mostUrgent(paces).map { [pace($0)] }
    }

    /// Over today's budget beats ahead of pace, which beats the rest. Plans outside the working day
    /// (not started, done, day off) have no pace to show. Ties keep the first plan, except that the
    /// further ahead of two plans ahead of pace wins.
    static func mostUrgent(_ paces: [LivePace]) -> LivePace? {
        func priority(_ state: LivePace.State) -> Int? {
            switch state {
            case .overBudget: 0
            case .ahead: 1
            case .warmingUp, .onPace, .behind: 2
            case .notStarted, .dayDone, .dayOff: nil
            }
        }
        var best: (live: LivePace, priority: Int)?
        for live in paces {
            guard let rank = priority(live.state) else { continue }
            if let current = best {
                if rank > current.priority { continue }
                if rank == current.priority {
                    guard rank == 1, (live.ahead ?? 0) > (current.live.ahead ?? 0) else { continue }
                }
            }
            best = (live, rank)
        }
        return best?.live
    }

    /// "+6.3%" chip over today's budget, "+41m" ahead (orange), "−2h 40m" under (green), "On pace".
    /// The minutes are colored the way the dashboard's pill is (`LivePace.tone`), so a figure that is
    /// ahead now but slowing down stays plain.
    static func pace(_ live: LivePace) -> MenuBarSpan {
        if live.state == .overBudget {
            return MenuBarSpan("+" + LivePaceFormat.percent(max(0, live.used - live.budget)), .chip)
        }
        let ahead = live.ahead ?? 0
        if abs(ahead) < LivePace.onPaceMargin {
            return MenuBarSpan(String(localized: "On pace", comment: "Menu bar team segment and pace pill: right on the plan's pace. Keep it short."), .dim)
        }
        let text = (ahead > 0 ? "+" : "−") + duration(ahead)
        switch live.tone {
        case .hot: return MenuBarSpan(text, .warning)
        case .cool: return MenuBarSpan(text, .positive)
        case .neutral: return MenuBarSpan(text)
        }
    }

    /// Tooltip and VoiceOver detail: your share of the team's spend today, which the strip doesn't show.
    static func detail(_ standing: Standing) -> String {
        guard let share = standing.share else { return String(localized: "Team") }
        return String(localized: "Team: \(share) of the team’s spend today", comment: "Menu bar team segment tooltip: your share of the team's spend today, e.g. 42%")
    }

    /// "41m", "2h 40m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    /// "45m", "2h", "3d" (Italian "3g").
    static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 48 * 60 {
            let days = minutes / (24 * 60)
            return String(localized: "\(days)d", comment: "Compact duration: days")
        }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// "$37". Dollars stay American in every language.
    static func wholeDollars(_ value: Double) -> String {
        "$\(Int(max(0, value).rounded()))"
    }
}
