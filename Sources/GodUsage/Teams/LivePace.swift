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
        /// Today's use went past its budget by at least 0.1% (what the labels can show).
        case overBudget
        /// Today's use reads the same as its budget at one decimal: the budget is used up, nothing is
        /// taken from the days after yet.
        case atBudget
        /// The first working hour: too early to judge the pace.
        case warmingUp
        /// On pace to end well over today's budget.
        case ahead
        case onPace
        /// On pace to leave much of today's budget unused.
        case behind

        /// The day is under way, so the pace means something.
        var isWorking: Bool { [.warmingUp, .ahead, .onPace, .behind, .overBudget, .atBudget].contains(self) }
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

    enum Tone: Equatable {
        /// Orange: ahead of pace now and heading over today's budget, or already at or over it.
        case hot
        /// Green: behind pace now and heading well under today's budget.
        case cool
        case neutral
    }

    /// The figure's color. The minutes say where today's use stands now, the state where the current
    /// pace leads by the end of the day; the figure is colored only when both agree. Ahead now but
    /// slowing down (or behind but speeding up) stays neutral, so "+9 min" is never green.
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

    /// Within this much working time of where today's use should be, the figure reads "On Pace".
    static let onPaceMargin: TimeInterval = 5 * 60

    /// "9 min ahead of pace." or "1h 05m behind pace.", with a turn when the pace points the other way.
    private var standing: String {
        let minutes = ahead ?? 0
        if abs(minutes) < Self.onPaceMargin { return String(localized: "On pace so far.", comment: "Live Pace alert: today's use is where it should be") }
        let duration = LivePaceFormat.duration(minutes)
        switch (minutes > 0, state) {
        case (true, .behind), (true, .onPace):
            return String(localized: "\(duration) ahead of pace, but slowing down.", comment: "Live Pace alert; the value is a duration, e.g. 9 min")
        case (false, .ahead):
            return String(localized: "\(duration) behind pace, but speeding up.", comment: "Live Pace alert; the value is a duration, e.g. 9 min")
        case (true, _):
            return String(localized: "\(duration) ahead of pace.", comment: "Live Pace alert; the value is a duration, e.g. 9 min")
        case (false, _):
            return String(localized: "\(duration) behind pace.", comment: "Live Pace alert; the value is a duration, e.g. 9 min")
        }
    }

    /// The last working day before the reset: what today leaves is lost, not moved.
    var isLastDay: Bool { futureDays.isEmpty }
    /// Today's use for the bars: the budget itself when the two read the same, so a full bar has no
    /// overflow sliver the labels can't explain.
    var shownUsed: Double { state == .atBudget ? budget : used }
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
                ? (day.day, remaining * day.hours / futureHours, plannedRemaining * day.hours / futureHours)
                : (day.day, 0, 0)
        }
    }

    /// How far `used` is past `budget`, rounded to one decimal the way the labels show percentages
    /// (`AppLocale.percent`): 0 when the two read the same, so "0.0% over" never shows.
    static func shownOvershoot(used: Double, budget: Double) -> Double {
        let shown = AppLocale.decimal(used - budget, digits: 1, locale: AppLocale.stable)
        return Double(shown) ?? used - budget
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

    /// The alert's title and body. The body is whole sentences, each its own catalog key, joined by spaces.
    func alertMessage(_ alert: Alert, plan: String, resetsAt: Date?, nextDays: String) -> (title: String, body: String) {
        let endTime = end.map { LivePaceFormat.time($0) } ?? ""
        let allowed = allowedRate.map { LivePaceFormat.rate($0) } ?? ""
        var sentences = [standing]
        switch alert {
        case .slowDown:
            if let runsOutAt {
                let time = LivePaceFormat.time(runsOutAt)
                sentences.append(String(localized: "At this rate today’s budget runs out at \(time).", comment: "Live Pace Slow Down alert; the value is a time"))
            }
            sentences.append(String(localized: "Stay under \(allowed) to last until \(endTime).", comment: "Live Pace Slow Down alert: a rate (10.0%/h), then the end of the working day"))
            return (String(localized: "Slow Down on \(plan)", comment: "Live Pace alert title; the value is a plan name"), sentences.joined(separator: " "))
        case .roomToSpare:
            sentences.append(String(localized: "Up to \(allowed) still fits until \(endTime).", comment: "Live Pace Room to Spare alert: a rate (10.0%/h), then the end of the working day"))
            let unused = LivePaceFormat.percent(projectedUnused)
            if isLastDay {
                if let resetsAt {
                    let reset = LivePaceFormat.weekdayTime(resetsAt)
                    sentences.append(String(localized: "At this rate \(unused) of your weekly limit is lost at the reset \(reset).", comment: "Live Pace Room to Spare alert: a percentage, then the reset's weekday and time (Mon 09:00)"))
                } else {
                    sentences.append(String(localized: "At this rate \(unused) of your weekly limit is lost at the reset.", comment: "Live Pace Room to Spare alert; the value is a percentage"))
                }
            } else {
                sentences.append(String(localized: "At this rate \(unused) of today’s budget moves to \(nextDays).", comment: "Live Pace Room to Spare alert: a percentage, then the next working days (Fri and Mon)"))
            }
            return (String(localized: "Room to Spare on \(plan)", comment: "Live Pace alert title; the value is a plan name"), sentences.joined(separator: " "))
        }
    }
}

/// Live Pace's numbers, days and times, in the app's language (`AppLocale`): "10.0%/h" / "10,0%/h",
/// "Wed" / "mer". Each takes the locale so tests can pin one.
enum LivePaceFormat {
    /// "6.3%" / "6,3%".
    static func percent(_ value: Double, locale: Locale = AppLocale.current) -> String {
        AppLocale.percent(value, locale: locale)
    }

    /// "10.0%/h" / "10,0%/h".
    static func rate(_ value: Double, locale: Locale = AppLocale.current) -> String {
        String(localized: "\(AppLocale.percent(value, locale: locale))/h", comment: "Live Pace: a rate of the weekly limit per hour, e.g. 10.0%/h")
    }

    /// "44 min", "1h 05m"; the sign is the caller's.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        guard minutes >= 60 else { return String(localized: "\(minutes) min", comment: "A duration in minutes, e.g. 44 min") }
        let hours = minutes / 60
        let rest = String(format: "%02d", minutes % 60)
        return String(localized: "\(hours)h \(rest)m", comment: "A duration in hours and minutes, e.g. 1h 05m")
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    /// "Mon 09:00" / "lun 09:00": the weekday in the app's language, the time in the Mac's format.
    static func weekdayTime(_ date: Date, locale: Locale = AppLocale.current) -> String {
        "\(weekday(date, locale: locale)) \(time(date))"
    }

    /// "Mon" / "lun", in the app's language whatever the Mac's, so it matches the app's own words.
    static func weekday(_ day: String, locale: Locale = AppLocale.current) -> String {
        guard let date = TeamsFormat.date(day) else { return day }
        return weekday(date, locale: locale)
    }

    static func weekday(_ date: Date, locale: Locale = AppLocale.current) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    /// A day's label in the week's strip: "Today" / "Oggi", else its weekday.
    static func dayLabel(_ day: String, today: String, locale: Locale = AppLocale.current) -> String {
        day == today ? String(localized: "Today") : weekday(day, locale: locale)
    }

    /// "Fri and Mon" / "ven e lun", as a list in the app's language.
    static func days(_ days: [String], locale: Locale = AppLocale.current) -> String {
        AppLocale.list(days.map { weekday($0, locale: locale) }, locale: locale)
    }

    /// The working days left as one span: "Wed", "Fri and Mon", or "Wed–Mon" for three or more.
    static func dayRange(_ days: [String], locale: Locale = AppLocale.current) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        guard days.count >= 3 else { return self.days(days, locale: locale) }
        return String(localized: "\(weekday(first, locale: locale))–\(weekday(last, locale: locale))", comment: "A range of weekdays, e.g. Wed–Mon")
    }
}
