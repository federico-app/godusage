import CoreGraphics
import Foundation

/// What a plan's Live Pace Details show, worked out from `LivePace`: the two rate tiles, the hours
/// line with who else's hours count, and the words for the day chart. Pure, so it is unit-tested;
/// the views only draw it.
enum LivePaceDetails {
    // MARK: - Rates

    /// The two tiles: the pace now ("PACE NOW", nil when there's no rate yet) and the pace that lasts
    /// until the end of the working day ("TO LAST UNTIL 18:30"). Nil outside the working day and over
    /// today's budget, where no pace fits.
    static func rates(_ live: LivePace) -> (now: String?, allowed: String, until: String)? {
        guard [.ahead, .onPace, .behind, .warmingUp].contains(live.state), let allowed = live.allowedRate, let end = live.end else { return nil }
        return (live.rate.map { LivePaceFormat.rate($0) }, LivePaceFormat.rate(allowed), LivePaceFormat.time(end))
    }

    /// PACE NOW's color: the plan's own (orange running hot, green well under), so the tile and the
    /// pill agree.
    static func paceNowTone(_ live: LivePace) -> LivePace.Tone { live.tone }

    // MARK: - Hours

    /// "9:00–13:15 · 14:00–18:30", or "No working hours today".
    static func hours(_ spans: [DateInterval]) -> String {
        guard !spans.isEmpty else { return String(localized: "No working hours today", comment: "Live Pace Details: the hours line on a day off") }
        return spans.map { "\(LivePaceFormat.time($0.start))–\(LivePaceFormat.time($0.end))" }.joined(separator: " · ")
    }

    /// The first letter of the first two words of a display name: "Matteo Scoccia" → "MS".
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// A hue in 0..<1 that a name always gets, on every Mac and every launch (`hashValue` changes per
    /// launch, so this is FNV-1a over the name's UTF-8).
    static func hue(_ name: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }

    /// The names that get a circle (at most `limit`) and how many more there are ("+N").
    static func avatars(_ names: [String], limit: Int = 3) -> (shown: [String], more: Int) {
        (Array(names.prefix(limit)), max(0, names.count - limit))
    }

    /// The circles' tooltip and accessibility label.
    static func sharedWith(_ names: [String]) -> String {
        let list = AppLocale.list(names)
        return String(localized: "Shared with \(list)", comment: "Live Pace Details: whose working hours also count; the value is a list of names")
    }

    // MARK: - Chart

    /// Which way today's use stands from the even pace now, for the area between them.
    enum Shade: Equatable {
        /// Use above the even pace: orange.
        case ahead
        /// Use under the even pace: green.
        case behind
    }

    /// Nil outside the working day and within `LivePace.onPaceMargin` of the even pace, where the pill
    /// says "On pace".
    static func shade(_ live: LivePace) -> Shade? {
        guard live.state.isWorking, let ahead = live.ahead, abs(ahead) >= LivePace.onPaceMargin else { return nil }
        return ahead > 0 ? .ahead : .behind
    }

    /// The chart in one sentence: "Today’s use is ahead of even pace; at this pace the budget runs out at 13:10."
    static func chartSummary(_ live: LivePace) -> String {
        let used = LivePaceFormat.percent(live.used)
        let budget = LivePaceFormat.percent(live.budget)
        switch live.state {
        case .ahead, .onPace, .behind, .warmingUp:
            if let runsOutAt = live.runsOutAt {
                let time = LivePaceFormat.time(runsOutAt)
                return switch shade(live) {
                case .ahead: String(localized: "Today’s use is ahead of even pace; at this pace the budget runs out at \(time).", comment: "Live Pace chart summary; the value is a time")
                case .behind: String(localized: "Today’s use is behind even pace; at this pace the budget runs out at \(time).", comment: "Live Pace chart summary; the value is a time")
                case nil: String(localized: "Today’s use is on even pace; at this pace the budget runs out at \(time).", comment: "Live Pace chart summary; the value is a time")
                }
            }
            let projected = LivePaceFormat.percent(live.projected)
            return switch shade(live) {
            case .ahead: String(localized: "Today’s use is ahead of even pace; at this pace today ends at \(projected) of its \(budget) budget.", comment: "Live Pace chart summary: two percentages of the weekly limit")
            case .behind: String(localized: "Today’s use is behind even pace; at this pace today ends at \(projected) of its \(budget) budget.", comment: "Live Pace chart summary: two percentages of the weekly limit")
            case nil: String(localized: "Today’s use is on even pace; at this pace today ends at \(projected) of its \(budget) budget.", comment: "Live Pace chart summary: two percentages of the weekly limit")
            }
        case .overBudget:
            return String(localized: "Today’s use is over its budget: \(used) of \(budget).", comment: "Live Pace chart summary: two percentages of the weekly limit")
        case .notStarted:
            let start = live.start.map(LivePaceFormat.time) ?? ""
            return String(localized: "The working day starts at \(start); today’s budget is \(budget).", comment: "Live Pace chart summary: a time, then a percentage")
        case .dayDone:
            return String(localized: "The working day is over; today used \(used) of its \(budget) budget.", comment: "Live Pace chart summary: two percentages of the weekly limit")
        case .dayOff:
            return String(localized: "No working hours today.", comment: "Live Pace chart summary on a day off")
        }
    }
}

/// Where the day chart's words go. Pure geometry, so it is unit-tested.
enum LivePaceChartLayout {
    /// How far across the chart `date` falls, 0 at the start of the working day and `width` at its end.
    static func x(_ date: Date, start: Date, end: Date, width: CGFloat) -> CGFloat {
        guard end > start else { return 0 }
        return CGFloat(date.timeIntervalSince(start) / end.timeIntervalSince(start)) * width
    }

    /// Where the current pace crosses the budget, across the chart; nil when it doesn't today or the
    /// pace isn't drawn.
    static func crossing(_ live: LivePace, width: CGFloat) -> CGFloat? {
        guard live.state.isWorking, let runsOutAt = live.runsOutAt, let start = live.start, let end = live.end else { return nil }
        return x(runsOutAt, start: start, end: end, width: width)
    }

    /// The center of a label `labelWidth` wide, as close to `x` as fits inside `0...width`.
    static func clampedCenter(_ x: CGFloat, labelWidth: CGFloat, in width: CGFloat) -> CGFloat {
        guard labelWidth < width else { return width / 2 }
        return min(max(x, labelWidth / 2), width - labelWidth / 2)
    }

    /// Labels `height` tall wanting to sit at `centers`: each one moved as little as it takes for no
    /// two to overlap, kept inside `bounds` (top and bottom edges). Labels that collide move as a
    /// stack centered on where they wanted to be. Returned in the order given. When they can't all
    /// fit, they stack from the top.
    static func nudge(_ centers: [CGFloat], height: CGFloat, within bounds: ClosedRange<CGFloat>) -> [CGFloat] {
        let low = bounds.lowerBound + height / 2
        let high = max(low, bounds.upperBound - height / 2)
        let order = centers.indices.sorted { centers[$0] < centers[$1] }
        // Each stack: where its first label sits, and the centers its labels wanted.
        var stacks: [(first: CGFloat, wanted: [CGFloat])] = []
        func place(_ wanted: [CGFloat]) -> CGFloat {
            let ideal = wanted.enumerated().reduce(0) { $0 + $1.element - CGFloat($1.offset) * height } / CGFloat(wanted.count)
            return max(min(ideal, high - CGFloat(wanted.count - 1) * height), low)
        }
        for index in order {
            var stack = (first: place([centers[index]]), wanted: [centers[index]])
            while let previous = stacks.last, previous.first + CGFloat(previous.wanted.count) * height > stack.first {
                stacks.removeLast()
                let wanted = previous.wanted + stack.wanted
                stack = (place(wanted), wanted)
            }
            stacks.append(stack)
        }
        let placed = stacks.flatMap { stack in stack.wanted.indices.map { stack.first + CGFloat($0) * height } }
        var result = centers
        for (rank, index) in order.enumerated() { result[index] = placed[rank] }
        return result
    }

    /// Whether two labels on one row, given as center and width, would touch (with `gap` between).
    static func overlap(_ a: (center: CGFloat, width: CGFloat), _ b: (center: CGFloat, width: CGFloat), gap: CGFloat = 4) -> Bool {
        abs(a.center - b.center) < (a.width + b.width) / 2 + gap
    }
}
