import Foundation

// Ported from the Mac's `Sources/GodUsage/Teams/LivePace.swift`. Keep the two in step: the same
// thresholds, states, and arithmetic, so a plan reads the same on the phone and on the Mac. The phone
// leaves out the alerts (it sends no notifications).

/// Today's budget over working hours, from the server (`budget.pace` in `/plans`, see the backend's
/// livePace.ts). The app turns it into the figures that move with the clock in `LivePace`.
struct TeamPlanPace: Decodable, Hashable, Sendable {
    /// A span of working time, ISO 8601.
    struct Span: Decodable, Hashable, Sendable {
        var from: String
        var to: String

        var interval: DateInterval? {
            guard let start = TeamsFormat.instant(from), let end = TeamsFormat.instant(to), end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    struct FutureDay: Decodable, Hashable, Sendable {
        var day: String
        var hours: Double
    }

    /// A reset claimed today: today's budget restarts at `at`, where today's use was `usedPercent`.
    struct Rebase: Decodable, Hashable, Sendable {
        var at: String
        var usedPercent: Double
    }

    /// What was left at the start of today times today's share of the working hours until the reset.
    var budgetPercent: Double
    var usedPercent: Double
    /// The share left at the start of today.
    var leftPercent: Double
    /// Growth over the last working hour, points per hour. Nil in the first working hour or without old enough readings.
    var ratePerHour: Double?
    /// Today's working hours: the union of everyone who uses the plan's accounts.
    var hours: [Span]
    /// The days after today until the reset that have working hours.
    var futureDays: [FutureDay]
    var resetsAt: String?
    /// Nil without a claim today, and for plans of several accounts.
    var rebase: Rebase?
}

/// Live Pace: where today's use stands against where it should be at this hour of the working day,
/// and what that means for the rest of the day and the week.
struct LivePace: Equatable {
    enum State: String, Equatable {
        /// No working hours today.
        case dayOff
        case notStarted
        case dayDone
        /// Today's use went past its budget by at least 0.1% (what the labels can show).
        case overBudget
        /// Today's use reads the same as its budget at one decimal.
        case atBudget
        /// The first working hour: too early to judge the pace.
        case warmingUp
        /// On pace to end well over today's budget.
        case ahead
        case onPace
        /// On pace to leave much of today's budget unused.
        case behind
    }

    /// The color goes orange above this share of today's budget at the current pace, and back under `aheadExit`.
    static let aheadEnter = 1.10
    static let aheadExit = 1.00
    /// It goes green below this share, and back over `behindExit`.
    static let behindEnter = 0.70
    static let behindExit = 0.80
    static let warmUp: TimeInterval = 3600
    /// Within this much working time of where today's use should be, the figure reads "On pace".
    static let onPaceMargin: TimeInterval = 5 * 60

    var state: State
    var budget: Double
    var used: Double
    /// Where today's use should be now: the budget times the share of today's working time gone by.
    var expected: Double
    /// How far ahead of that use is, in working time (negative when behind). Nil without a budget.
    var ahead: TimeInterval?
    /// Points per working hour: the last working hour's, or today's average when the server can't tell.
    var rate: Double?
    /// Where today ends at the current pace.
    var projected: Double
    /// When today's budget runs out at the current pace, if before the end of the working day.
    var runsOutAt: Date?
    var start: Date?
    var end: Date?
    var workedSoFar: TimeInterval
    var workLeft: TimeInterval
    /// Each working day after today until the reset, at what's left once today ends, and at its plan.
    var futureDays: [FutureDay]

    struct FutureDay: Equatable {
        var day: String
        var budget: Double
        var planned: Double
    }

    enum Tone: Equatable {
        /// Orange: ahead of pace now and heading over today's budget, or already at or over it.
        case hot
        /// Green: behind pace now and heading well under today's budget.
        case cool
        case neutral
    }

    /// The figure's color: colored only when where today's use stands now and where the current pace
    /// leads agree, so "+9 min" is never green.
    var tone: Tone {
        let minutes = ahead ?? 0
        let clear = abs(minutes) >= Self.onPaceMargin
        switch state {
        case .overBudget, .atBudget: return .hot
        case .ahead: return clear && minutes > 0 ? .hot : .neutral
        case .behind: return clear && minutes < 0 ? .cool : .neutral
        default: return .neutral
        }
    }

    /// The last working day before the reset: what today leaves is lost, not moved.
    var isLastDay: Bool { futureDays.isEmpty }
    /// Today's use for the bars: the budget itself when the two read the same.
    var shownUsed: Double { state == .atBudget ? budget : used }

    init(pace: TeamPlanPace, now: Date, previous: State? = nil) {
        let spans = pace.hours.compactMap(\.interval)
        budget = pace.budgetPercent
        used = pace.usedPercent
        start = spans.first?.start
        end = spans.last?.end
        let total = spans.reduce(0) { $0 + $1.duration }
        let rebase = pace.rebase.flatMap { rebase in TeamsFormat.instant(rebase.at).map { (at: $0, used: rebase.usedPercent) } }
        workedSoFar = Self.overlap(spans, until: now)
        workLeft = max(0, total - workedSoFar)
        expected = Self.evenPace(spans: spans, budget: pace.budgetPercent, rebase: rebase, at: now)
        let slope = Self.evenPaceSlope(spans: spans, budget: pace.budgetPercent, rebase: rebase, at: now)
        ahead = budget > 0 && slope > 0 ? (used - expected) / slope : nil
        let averageRate = workedSoFar >= Self.warmUp ? used / (workedSoFar / 3600) : nil
        rate = pace.ratePerHour ?? averageRate
        projected = used + (rate ?? 0) * workLeft / 3600
        runsOutAt = nil
        if let rate, rate > 0, used < budget {
            runsOutAt = Self.workingTime(spans, after: now, hours: (budget - used) / rate)
        }

        if spans.isEmpty {
            state = .dayOff
        } else if let start, now < start {
            state = .notStarted
        } else if let end, now >= end {
            state = .dayDone
        } else if Self.shownOvershoot(used: used, budget: budget) > 0 {
            state = .overBudget
        } else if Self.shownOvershoot(used: used, budget: budget) == 0 {
            state = .atBudget
        } else if workedSoFar < Self.warmUp {
            state = .warmingUp
        } else {
            let share = projected / budget
            switch previous {
            case .ahead where share >= Self.aheadExit: state = .ahead
            case .behind where share <= Self.behindExit: state = .behind
            default: state = share > Self.aheadEnter ? .ahead : share < Self.behindEnter ? .behind : .onPace
            }
        }

        // The days after today share what today leaves: today counts at its budget, or more when it
        // is (or is heading) over; a finished day counts at what it used.
        let todayEnd: Double = switch state {
        case .dayDone, .dayOff: used
        case .notStarted: budget
        default: max(budget, projected, used)
        }
        let futureHours = pace.futureDays.reduce(0) { $0 + $1.hours }
        let remaining = max(0, pace.leftPercent - todayEnd)
        let plannedRemaining = max(0, pace.leftPercent - budget)
        futureDays = pace.futureDays.map { day in
            futureHours > 0
                ? FutureDay(day: day.day, budget: remaining * day.hours / futureHours, planned: plannedRemaining * day.hours / futureHours)
                : FutureDay(day: day.day, budget: 0, planned: 0)
        }
    }

    /// How far `used` is past `budget`, rounded to one decimal the way the labels show percentages:
    /// 0 when the two read the same, so "0.0% over" never shows.
    static func shownOvershoot(used: Double, budget: Double) -> Double {
        let shown = (used - budget).formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(Locale(identifier: "en_US")))
        return Double(shown) ?? used - budget
    }

    /// Where today's use should be at `date` on an even pace. With a reset claimed today, the even pace
    /// reaches the use at the claim when the claim came, then restarts from there to the budget.
    static func evenPace(spans: [DateInterval], budget: Double, rebase: (at: Date, used: Double)?, at date: Date) -> Double {
        let total = spans.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let worked = overlap(spans, until: date)
        guard let rebase else { return budget * worked / total }
        let atClaim = overlap(spans, until: rebase.at)
        if date < rebase.at { return atClaim > 0 ? rebase.used * worked / atClaim : rebase.used }
        let after = total - atClaim
        return after > 0 ? rebase.used + (budget - rebase.used) * (worked - atClaim) / after : budget
    }

    /// The even pace in points per second of working time at `date`.
    static func evenPaceSlope(spans: [DateInterval], budget: Double, rebase: (at: Date, used: Double)?, at date: Date) -> Double {
        let total = spans.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        guard let rebase else { return budget / total }
        let atClaim = overlap(spans, until: rebase.at)
        if date < rebase.at { return atClaim > 0 ? rebase.used / atClaim : 0 }
        let after = total - atClaim
        return after > 0 ? max(0, budget - rebase.used) / after : 0
    }

    /// How much of `spans` passed before `date`.
    static func overlap(_ spans: [DateInterval], until date: Date) -> TimeInterval {
        spans.reduce(0) { sum, span in sum + max(0, min(date, span.end).timeIntervalSince(span.start)) }
    }

    /// The instant `hours` of working time after `date`, or nil when the working day ends first.
    static func workingTime(_ spans: [DateInterval], after date: Date, hours: Double) -> Date? {
        var needed = hours * 3600
        for span in spans where span.end > date {
            let from = max(span.start, date)
            let available = span.end.timeIntervalSince(from)
            if available >= needed { return from.addingTimeInterval(needed) }
            needed -= available
        }
        return nil
    }
}

/// Live Pace's numbers, days, and times in the app's language: "10.0%" / "10,0%", "Wed" / "mer".
enum LivePaceFormat {
    /// One decimal, like the Mac's This Week's Limit: "6.3%" / "6,3%".
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(TeamsFormat.numberLocale)) + "%"
    }

    /// "44 min", "1h 05m"; the sign is the caller's.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        guard minutes >= 60 else { return String(localized: "\(minutes) min", comment: "A duration in minutes, e.g. 44 min") }
        let hours = minutes / 60
        let rest = String(format: "%02d", minutes % 60)
        return String(localized: "\(hours)h \(rest)m", comment: "A duration in hours and minutes, e.g. 1h 05m")
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(TeamsFormat.dateLocale))
    }

    static func weekday(_ day: String) -> String {
        guard let date = TeamsFormat.day(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(TeamsFormat.dateLocale))
    }

    /// A day's label in the week's boxes: "Today" / "Oggi", else its weekday.
    static func dayLabel(_ day: String, today: String) -> String {
        day == today ? String(localized: "Today") : weekday(day)
    }

    /// The working days left as one span: "Wed", "Fri and Mon", or "Wed–Mon" for three or more.
    static func dayRange(_ days: [String]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        guard days.count >= 3 else { return days.map(weekday).formatted(.list(type: .and).locale(TeamsFormat.dateLocale)) }
        return String(localized: "\(weekday(first))–\(weekday(last))", comment: "A range of weekdays, e.g. Wed–Mon")
    }
}
