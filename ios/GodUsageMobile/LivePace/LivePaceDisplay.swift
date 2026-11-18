import Foundation

// Ported from the Mac's `Sources/GodUsage/Teams/LivePaceDisplay.swift`: the same words and shapes
// for This Week's Limit. The phone has no Details (rates, hours, day chart).

/// What This Week's Limit shows for a plan, worked out from `LivePace`: the pill's words, today's
/// bar, the note under it, and the week's boxes. The views only draw it.
enum LivePaceDisplay {
    enum PillStyle: Equatable {
        case hot
        case cool
        case neutral
        case over
        case muted
    }

    /// A plan that's fine (not ahead of pace, not at or over today's budget) shows only its title and
    /// today's bar; its week opens with "Week".
    static func collapses(_ state: LivePace.State) -> Bool {
        ![.ahead, .overBudget, .atBudget].contains(state)
    }

    /// The one figure per plan, in words: "22 min ahead of pace", "2h 40m under pace", "On pace",
    /// "6.3% over today", "Today's budget used up", "Starts 9:00", "Day Done", "Day Off". The plan to
    /// use while another runs hot (`useThisNow`) is tinted green.
    static func pill(_ live: LivePace, useThisNow: Bool) -> (text: String, style: PillStyle) {
        let tone: PillStyle = switch live.tone {
        case .hot: .hot
        case .cool: .cool
        case .neutral: .neutral
        }
        switch live.state {
        case .ahead, .behind, .onPace, .warmingUp:
            let ahead = live.ahead ?? 0
            let duration = LivePaceFormat.duration(ahead)
            let style = useThisNow ? .cool : tone
            if abs(ahead) < LivePace.onPaceMargin { return (String(localized: "On pace", comment: "Live Pace pill: today's use is where it should be"), style) }
            let text = ahead > 0
                ? String(localized: "\(duration) ahead of pace", comment: "Live Pace pill; the value is a duration, e.g. 22 min")
                : String(localized: "\(duration) under pace", comment: "Live Pace pill; the value is a duration, e.g. 2h 40m")
            return (text, style)
        case .overBudget:
            let over = LivePaceFormat.percent(max(0, live.used - live.budget))
            return (String(localized: "\(over) over today", comment: "Live Pace pill: how far today's use went past today's budget, e.g. 6.3% over today"), .over)
        case .atBudget:
            return (String(localized: "Today’s budget used up", comment: "Live Pace pill: today's use reached today's budget exactly, nothing over yet"), .hot)
        case .notStarted:
            let start = live.start.map(LivePaceFormat.time) ?? ""
            return (String(localized: "Starts \(start)", comment: "Live Pace pill before the working day; the value is a time"), .muted)
        case .dayDone:
            return (String(localized: "Day Done", comment: "Live Pace pill after the working day"), .muted)
        case .dayOff:
            return (String(localized: "Day Off", comment: "Live Pace pill on a day without working hours"), .muted)
        }
    }

    enum NoteStyle: Equatable {
        case notice
        case positive
        case secondary
    }

    /// The one thing to know next, under today's bar; nil when the pill and the bar say it all.
    static func note(_ live: LivePace) -> (text: String, style: NoteStyle)? {
        let next = live.futureDays.first
        let days = LivePaceFormat.dayRange(live.futureDays.map(\.day))
        switch live.state {
        case .ahead:
            if let runsOutAt = live.runsOutAt {
                let time = LivePaceFormat.time(runsOutAt)
                return (String(localized: "At this pace today’s budget runs out at \(time).", comment: "Live Pace note; the value is a time"), .notice)
            }
            let projected = LivePaceFormat.percent(live.projected)
            return (String(localized: "At this pace today ends at \(projected), over its budget.", comment: "Live Pace note; the value is a percentage of the weekly limit"), .notice)
        case .overBudget:
            if live.isLastDay {
                return (String(localized: "Over today’s budget, on the last working day before the reset.", comment: "Live Pace note"), .notice)
            }
            let over = LivePaceFormat.percent(max(0, live.used - live.budget))
            return (String(localized: "Today’s budget is used up. The \(over) comes out of the next working days.", comment: "Live Pace note; the value is the percentage over today's budget"), .notice)
        case .atBudget:
            return live.isLastDay
                ? (String(localized: "Today’s budget is used up, on the last working day before the reset.", comment: "Live Pace note: today's use reached today's budget exactly"), .notice)
                : (String(localized: "Today’s budget is used up. More today comes out of the next working days.", comment: "Live Pace note: today's use reached today's budget exactly"), .notice)
        case .onPace, .behind, .warmingUp, .notStarted:
            return nil
        case .dayDone:
            guard let next else { return nil }
            let budget = LivePaceFormat.percent(next.budget)
            if next.budget >= next.planned {
                return (String(localized: "\(days) rise to \(budget).", comment: "Live Pace note: the next working days' budget goes up, e.g. Wed–Mon rise to 18.4%"), .positive)
            }
            return (String(localized: "\(days) drop to \(budget).", comment: "Live Pace note: the next working days' budget goes down, e.g. Wed–Mon drop to 18.4%"), .notice)
        case .dayOff:
            guard let next else { return (String(localized: "No working days before the reset.", comment: "Live Pace note on a day off"), .secondary) }
            let budget = LivePaceFormat.percent(next.budget)
            return (String(localized: "\(budget) on \(days).", comment: "Live Pace note on a day off: the next working days' budget, e.g. 18.4% on Wed–Mon"), .secondary)
        }
    }

    /// Plans with room while another provider's plan runs hot (at or over today's budget, or well
    /// ahead of pace): their pill is tinted green. Room means on pace or behind, with at least
    /// `roomForOthers` points of today's budget left. Keyed by plan id.
    static func useThisNow(_ paces: [(plan: TeamPlans.Plan, live: LivePace)]) -> Set<String> {
        let hot = Set(paces.filter { [.ahead, .overBudget, .atBudget].contains($0.live.state) }.map(\.plan.provider))
        guard !hot.isEmpty else { return [] }
        return Set(paces.filter { entry in
            !hot.contains(entry.plan.provider) && [.onPace, .behind].contains(entry.live.state)
                && entry.live.budget - entry.live.used >= roomForOthers
        }.map(\.plan.id))
    }

    static let roomForOthers = 5.0
}

/// Today's bar: the track is today's budget and the fill today's use. Over the budget the track
/// stretches to the use, the budget becomes a tick, and the part past it is the overflow. All
/// positions are fractions of the track's width.
struct TodayBarGeometry: Equatable {
    var fill: Double
    var overflow: Double
    var budgetTick: Double?
    /// Where today's use should be now at an even pace; nil when the pace can't say.
    var nowTick: Double?

    init(used: Double, budget: Double, expected: Double?) {
        let used = max(0, used)
        let budget = max(0, budget)
        let scale = max(used, budget)
        guard scale > 0 else {
            fill = 0
            overflow = 0
            budgetTick = nil
            nowTick = nil
            return
        }
        if used > budget {
            fill = budget / scale
            overflow = (used - budget) / scale
            budgetTick = budget > 0 ? budget / scale : nil
        } else {
            fill = used / scale
            overflow = 0
            budgetTick = nil
        }
        nowTick = expected.map { min(max($0 / scale, 0), 1) }
    }

    /// The bar for a Live Pace row: the now tick only while the day is under way and under budget.
    init(_ live: LivePace) {
        let paced: [LivePace.State] = [.ahead, .onPace, .behind, .warmingUp]
        let expected = paced.contains(live.state) && live.budget > 0 && live.start != nil ? live.expected : nil
        self.init(used: live.shownUsed, budget: live.budget, expected: expected)
    }
}

/// One day in the week's boxes. Heights are shares of a full box, which stands for today's budget.
struct WeekBox: Equatable {
    enum Kind: Equatable {
        case past(fill: Double, estimated: Bool)
        case today(fill: Double, overflow: Double)
        case future(height: Double, lowered: Bool, label: String?)
        case off
        case empty
    }

    var day: String
    var label: String
    var isToday: Bool
    var kind: Kind
    var reset = false

    static let maxHeight = 1.3

    static func boxes(
        days: [TeamPlans.Day], today: String, used: Double, budget: Double,
        future: [LivePace.FutureDay], labelsLowered: Bool
    ) -> [WeekBox] {
        let reference = budget > 0 ? budget : max(future.map(\.planned).max() ?? 0, 1)
        func share(_ value: Double) -> Double { min(max(value, 0) / reference, maxHeight) }
        return days.map { day in
            let kind: Kind
            if day.day == today {
                kind = .today(fill: min(share(used), 1), overflow: budget > 0 ? min(share(used - budget), maxHeight - 1) : 0)
            } else if day.day > today {
                if let next = future.first(where: { $0.day == day.day }) {
                    let lowered = next.budget < next.planned - 0.05
                    kind = .future(
                        height: max(share(next.budget), 0.1), lowered: lowered,
                        label: labelsLowered && lowered ? LivePaceFormat.percent(next.budget) : nil
                    )
                } else {
                    kind = .off
                }
            } else if let percent = day.percent, percent > 0 || day.working == true {
                kind = .past(fill: share(percent), estimated: day.estimated == true)
            } else {
                kind = day.working == true ? .empty : .off
            }
            return WeekBox(
                day: day.day, label: LivePaceFormat.dayLabel(day.day, today: today), isToday: day.day == today, kind: kind,
                reset: (day.resets ?? 0) > 0
            )
        }
    }

    /// Without Live Pace: the working days left all at today's budget.
    static func boxes(_ budget: TeamPlans.Budget, today: String) -> [WeekBox] {
        let days = budget.days ?? []
        let future = days.filter { $0.day > today && $0.working == true }
            .map { LivePace.FutureDay(day: $0.day, budget: budget.affordablePercent, planned: budget.affordablePercent) }
        return boxes(days: days, today: today, used: budget.todayPercent, budget: budget.affordablePercent, future: future, labelsLowered: false)
    }
}
