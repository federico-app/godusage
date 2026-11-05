import Foundation

/// Today's budget over working hours, from the server (see the backend's livePace.ts). The app turns
/// it into the figures that move with the clock in `LivePace`.
struct TeamPlanPace: Decodable, Hashable, Sendable {
    /// A span of working time, ISO 8601.
    struct Span: Decodable, Hashable, Sendable {
        var from: String
        var to: String

        var interval: DateInterval? {
            guard let start = GodUsageISO8601.date(from: from), let end = GodUsageISO8601.date(from: to), end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    struct FutureDay: Decodable, Hashable, Sendable {
        var day: String
        var hours: Double
    }

    struct Point: Decodable, Hashable, Sendable {
        var at: String
        var percent: Double
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
    /// Today's use over time.
    var today: [Point]
    /// The other people whose hours are in `hours`.
    var sharedWith: [String]
    var resetsAt: String
}

/// Live Pace: where today's use stands against where it should be at this hour of the working day,
/// and what that means for the rest of the day and the week. Pure, so it is unit-tested.
struct LivePace: Equatable {
    enum State: String, Equatable {
        /// No working hours today.
        case dayOff
        case notStarted
        case dayDone
        /// Today's budget is used up.
        case overBudget
        /// The first working hour: too early to judge the pace.
        case warmingUp
        /// On pace to end well over today's budget.
        case ahead
        case onPace
        /// On pace to leave much of today's budget unused.
        case behind

        /// The day is under way, so the pace means something.
        var isWorking: Bool { [.warmingUp, .ahead, .onPace, .behind, .overBudget].contains(self) }
    }

    /// The color goes orange above this share of today's budget at the current pace, and back under `aheadExit`.
    static let aheadEnter = 1.10
    static let aheadExit = 1.00
    /// It goes green below this share, and back over `behindExit`.
    static let behindEnter = 0.70
    static let behindExit = 0.80
    static let warmUp: TimeInterval = 3600

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
    /// The pace that uses exactly the rest of today's budget by the end of the working day.
    var allowedRate: Double?
    /// When today's budget runs out at the current pace, if before the end of the working day.
    var runsOutAt: Date?
    var start: Date?
    var end: Date?
    var workedSoFar: TimeInterval
    var workLeft: TimeInterval
    /// Each working day after today until the reset, at what's left once today ends (`futureBudget`).
    var futureDays: [(day: String, budget: Double, planned: Double)]

    static func == (a: LivePace, b: LivePace) -> Bool {
        a.state == b.state && a.budget == b.budget && a.used == b.used && a.expected == b.expected && a.ahead == b.ahead
            && a.rate == b.rate && a.projected == b.projected && a.runsOutAt == b.runsOutAt
            && a.futureDays.map(\.day) == b.futureDays.map(\.day) && a.futureDays.map(\.budget) == b.futureDays.map(\.budget)
    }

    /// The last working day before the reset: what today leaves is lost, not moved.
    var isLastDay: Bool { futureDays.isEmpty }
    /// What today leaves of its budget at the current pace.
    var projectedUnused: Double { max(0, budget - projected) }

    init(pace: TeamPlanPace, now: Date, previous: State? = nil) {
        let spans = pace.hours.compactMap(\.interval)
        budget = pace.budgetPercent
        used = pace.usedPercent
        start = spans.first?.start
        end = spans.last?.end
        let total = spans.reduce(0) { $0 + $1.duration }
        workedSoFar = Self.overlap(spans, until: now)
        workLeft = max(0, total - workedSoFar)
        expected = total > 0 ? budget * workedSoFar / total : 0
        ahead = budget > 0 && total > 0 ? (used - expected) / (budget / total) : nil
        let averageRate = workedSoFar >= Self.warmUp ? used / (workedSoFar / 3600) : nil
        rate = pace.ratePerHour ?? averageRate
        projected = used + (rate ?? 0) * workLeft / 3600
        allowedRate = workLeft > 0 ? max(0, budget - used) / (workLeft / 3600) : nil
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
        } else if used >= budget {
            state = .overBudget
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
                ? (day.day, remaining * day.hours / futureHours, plannedRemaining * day.hours / futureHours)
                : (day.day, 0, 0)
        }
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

// MARK: - Alerts

extension LivePace {
    enum Alert: String {
        case slowDown
        case roomToSpare
    }

    /// Slow Down needs the budget to run out at least this long before the end of the working day.
    static let slowDownMargin: TimeInterval = 30 * 60
    /// Room to Spare needs at least this share of today's budget unused (less on the last day before the
    /// reset, when it's lost) and at least `roomMinimum` points of the weekly limit.
    static let roomShare = 0.30
    static let roomShareLastDay = 0.15
    static let roomMinimum = 3.0

    /// The alert this pace calls for, if any. `inYourHours` is whether you're working now.
    func alert(inYourHours: Bool) -> Alert? {
        guard inYourHours else { return nil }
        if state == .ahead, let runsOutAt, let end, runsOutAt <= end.addingTimeInterval(-Self.slowDownMargin) {
            return .slowDown
        }
        let share = isLastDay ? Self.roomShareLastDay : Self.roomShare
        if [.onPace, .behind].contains(state), workedSoFar >= workLeft, workLeft >= 3600,
           projectedUnused >= max(share * budget, Self.roomMinimum) {
            return .roomToSpare
        }
        return nil
    }

    func alertMessage(_ alert: Alert, plan: String, resetsAt: Date?, nextDays: String) -> (title: String, body: String) {
        let endTime = end.map { LivePaceFormat.time($0) } ?? ""
        let allowed = allowedRate.map { LivePaceFormat.rate($0) } ?? ""
        switch alert {
        case .slowDown:
            var body = "\(LivePaceFormat.duration(ahead ?? 0)) ahead of pace."
            if let runsOutAt { body += " At this rate today’s budget runs out at \(LivePaceFormat.time(runsOutAt))." }
            body += " Stay under \(allowed) to last until \(endTime)."
            return ("Slow Down on \(plan)", body)
        case .roomToSpare:
            var body = "\(LivePaceFormat.duration(ahead ?? 0)) behind pace. Up to \(allowed) still fits until \(endTime)."
            if isLastDay {
                let reset = resetsAt.map { " at the reset \(LivePaceFormat.weekdayTime($0))" } ?? " at the reset"
                body += " At this rate \(LivePaceFormat.percent(projectedUnused)) of your weekly limit is lost\(reset)."
            } else {
                body += " At this rate \(LivePaceFormat.percent(projectedUnused)) of today’s budget moves to \(nextDays)."
            }
            return ("Room to Spare on \(plan)", body)
        }
    }
}

enum LivePaceFormat {
    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    static func rate(_ value: Double) -> String { String(format: "%.1f%%/h", value) }

    /// "44 min", "1h 05m"; the sign is the caller's.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    /// "+44 min" ahead, "−1h 05m" behind, "On Pace" within five minutes.
    static func signedDuration(_ seconds: TimeInterval) -> String {
        if abs(seconds) < 5 * 60 { return "On Pace" }
        return (seconds > 0 ? "+" : "−") + duration(seconds)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func weekdayTime(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }

    static func weekday(_ day: String) -> String {
        guard let date = TeamsFormat.date(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "Fri, Mon".
    static func days(_ days: [String]) -> String { days.map(weekday).joined(separator: ", ") }
}
