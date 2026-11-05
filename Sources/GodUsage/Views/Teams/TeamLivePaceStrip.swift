import SwiftUI

/// One plan in This Week's Limit with Live Pace on: how far ahead of or behind today's pace you are,
/// as the plan's figure, the week's strip with a tick where today should be now, and Details with
/// the pace that fits the rest of the day, the working hours, and the day chart.
struct TeamLivePaceStrip: View {
    let plan: TeamPlanReport
    let budget: TeamPlanBudget
    let pace: TeamPlanPace
    let live: LivePace
    /// Another plan is running hot and this one has room: say so on this one.
    let useThisNow: Bool
    let today: String
    var teamName: String?

    @State private var showsDetails = false
    private static let height: CGFloat = 40
    private var color: Color { TotalSpendPalette.color(for: plan.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            subline
            bars
            details
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            (Text(plan.name).font(.caption.weight(.semibold))
                + Text(teamName.map { "  \($0)" } ?? "").font(.caption2).foregroundStyle(.secondary))
                .lineLimit(1)
            if budget.accounts > 1 {
                Text("\(budget.accounts) accounts").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor).fixedSize()
            }
            Spacer(minLength: 4)
            figure
        }
    }

    /// The one number per plan: minutes ahead (orange) or behind (green), how far over, or the day's status.
    private var figure: some View {
        let (text, style): (String, AnyShapeStyle) = switch live.state {
        case .ahead: (LivePaceFormat.signedDuration(live.ahead ?? 0), Theme.notice)
        case .behind: (LivePaceFormat.signedDuration(live.ahead ?? 0), Theme.positive)
        case .onPace, .warmingUp: (LivePaceFormat.signedDuration(live.ahead ?? 0), AnyShapeStyle(.primary))
        case .overBudget: ("+" + LivePaceFormat.percent(live.used - live.budget), Theme.notice)
        case .notStarted: ("Starts \(live.start.map(LivePaceFormat.time) ?? "")", AnyShapeStyle(.secondary))
        case .dayDone: ("Day Done", AnyShapeStyle(.secondary))
        case .dayOff: ("Day Off", AnyShapeStyle(.secondary))
        }
        let big = live.state.isWorking
        return Text(text)
            .font(big ? .system(size: 14, weight: .bold).monospacedDigit() : .caption.weight(.semibold))
            .foregroundStyle(style)
            .fixedSize()
            .hoverTooltip(figureTooltip)
    }

    /// What the figure means, in words: the minutes are working time against the pace that uses
    /// exactly today's budget by the end of the working day.
    private var figureTooltip: String {
        let end = live.end.map { " until \(LivePaceFormat.time($0))" } ?? ""
        let even = "An even pace spreads today’s budget (\(LivePaceFormat.percent(live.budget))) over the working hours\(end)."
        let duration = LivePaceFormat.duration(live.ahead ?? 0)
        switch live.state {
        case .ahead, .onPace, .behind, .warmingUp:
            let ahead = live.ahead ?? 0
            var text = abs(ahead) < 5 * 60
                ? "You’re right on pace."
                : ahead > 0
                    ? "You’re \(duration) ahead of pace: you’ve already used what an even pace would reach only in \(duration) more of working time."
                    : "You’re \(duration) behind pace: an even pace would have reached your use \(duration) of working time ago, so you have room to spare."
            text += " \(even) Now \(LivePaceFormat.percent(live.used)), expected \(LivePaceFormat.percent(live.expected))."
            if live.state == .warmingUp { text += " It’s too early in the day to color it." }
            return text
        case .overBudget:
            return "Today’s budget is used up: \(LivePaceFormat.percent(live.used - live.budget)) over. The working days until the reset get less."
        case .notStarted:
            return "Your working day hasn’t started yet. Today’s budget is \(LivePaceFormat.percent(live.budget))."
        case .dayDone:
            return "Your working day is over. What today left, or took over its budget, moves to the working days until the reset."
        case .dayOff:
            return "No working hours today: the weekly limit is spread over the working days until the reset."
        }
    }

    private var nextDays: String { LivePaceFormat.days(live.futureDays.map(\.day)) }
    private var nextBudget: Double { live.futureDays.first?.budget ?? 0 }

    /// Today's use against its budget, and the one thing to know next.
    private var subline: some View {
        let (note, style): (String, AnyShapeStyle) = switch live.state {
        case .ahead:
            if let runsOutAt = live.runsOutAt { ("budget ends \(LivePaceFormat.time(runsOutAt))", Theme.notice) } else { ("ahead of pace", Theme.notice) }
        case .overBudget:
            (live.isLastDay ? "over today’s budget" : "\(nextDays) drop to \(LivePaceFormat.percent(nextBudget))", Theme.notice)
        case .onPace, .behind, .warmingUp:
            useThisNow ? ("use this now", Theme.positive) : ("\(LivePaceFormat.percent(max(0, live.budget - live.used))) left today", AnyShapeStyle(.secondary))
        case .notStarted:
            ("\(LivePaceFormat.percent(live.budget)) to spend today", AnyShapeStyle(.secondary))
        case .dayDone:
            live.isLastDay
                ? ("\(LivePaceFormat.percent(live.used)) used", AnyShapeStyle(.secondary))
                : ("\(nextDays) \(nextBudget >= (live.futureDays.first?.planned ?? 0) ? "rise" : "drop") to \(LivePaceFormat.percent(nextBudget))",
                   nextBudget >= (live.futureDays.first?.planned ?? 0) ? Theme.positive : Theme.notice)
        case .dayOff:
            live.isLastDay ? ("no working days before the reset", AnyShapeStyle(.secondary))
                : ("\(LivePaceFormat.percent(nextBudget)) on \(nextDays)", AnyShapeStyle(.secondary))
        }
        return HStack(spacing: 6) {
            Text(live.state == .dayOff ? "\(LivePaceFormat.percent(live.used)) today" : "\(LivePaceFormat.percent(live.used)) of \(LivePaceFormat.percent(live.budget)) today")
            Spacer(minLength: 4)
            Text(note).foregroundStyle(style).lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: - Week strip

    private var scale: Double {
        let past = budget.days.compactMap(\.percent).max() ?? 0
        let future = live.futureDays.map { max($0.budget, $0.planned) }.max() ?? 0
        return max(live.budget * 1.2, future * 1.2, past, live.used, 1)
    }

    private func height(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0) / scale, 1)) * Self.height
    }

    private var bars: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(budget.days, id: \.day) { day in bar(day).frame(maxWidth: .infinity) }
            }
            .frame(height: Self.height, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }
            HStack(spacing: 3) {
                ForEach(budget.days, id: \.day) { day in
                    Text(day.day == today ? "Today" : LivePaceFormat.weekday(day.day))
                        .font(.system(size: 9, weight: day.day == today ? .semibold : .regular))
                        .foregroundStyle(day.day == today ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func bar(_ day: TeamPlanBudget.Day) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
        if day.day > today {
            // The working days left, at what today leaves them: orange when today took from them.
            if let future = live.futureDays.first(where: { $0.day == day.day }) {
                shape.strokeBorder((future.budget < future.planned - 0.05 ? Theme.noticeColor : color).opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(height: max(height(future.budget), 1))
            } else {
                Color.clear.frame(height: 0)
            }
        } else if day.day == today {
            ZStack(alignment: .bottom) {
                if live.budget > 0 {
                    shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: height(live.budget))
                }
                shape.fill((live.used > live.budget && live.budget > 0 ? Theme.noticeColor : color).opacity(0.8))
                    .frame(height: max(height(live.used), 2))
            }
            .overlay(alignment: .bottom) {
                // Where today's use should be at this hour.
                if live.state.isWorking {
                    Capsule().fill(.primary).frame(height: 2.5).padding(.horizontal, -3).offset(y: -height(live.expected) + 1.25)
                }
            }
        } else if let percent = day.percent {
            shape.fill(day.estimated ? color.opacity(0.4) : color).frame(height: max(height(percent), 2))
        } else {
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var details: some View {
        Button {
            withAnimation(Motion.spring) { showsDetails.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showsDetails ? 90 : 0))
                Text("Details").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDetails ? "Hide Details" : "Show Details")
        if showsDetails {
            VStack(alignment: .leading, spacing: 4) {
                if [.ahead, .onPace, .behind, .warmingUp].contains(live.state), let allowed = live.allowedRate, let end = live.end {
                    Text(rateLine(allowed: allowed, end: end)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(hoursLine).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !pace.hours.isEmpty {
                    LivePaceDayChart(pace: pace, live: live, color: color).frame(height: 64)
                }
            }
            .transition(.opacity)
        }
    }

    private func rateLine(allowed: Double, end: Date) -> String {
        let now = live.rate.map { "\(LivePaceFormat.rate($0)) now · " } ?? ""
        return "\(now)\(LivePaceFormat.rate(allowed)) lasts until \(LivePaceFormat.time(end))"
    }

    private var hoursLine: String {
        let spans = pace.hours.compactMap(\.interval)
        let hours = spans.isEmpty ? "no working hours today" : spans.map { "\(LivePaceFormat.time($0.start))–\(LivePaceFormat.time($0.end))" }.joined(separator: ", ")
        let shared = pace.sharedWith.isEmpty ? "" : " · shared with \(pace.sharedWith.joined(separator: ", "))"
        return "Hours: \(hours)\(shared)"
    }
}

/// Today over the working hours: the ideal pace to the budget (dashed), the use so far (solid), and
/// where the current pace leads (dotted), with the breaks shaded.
struct LivePaceDayChart: View {
    let pace: TeamPlanPace
    let live: LivePace
    let color: Color

    var body: some View {
        let spans = pace.hours.compactMap(\.interval)
        let points = pace.today.compactMap { point in GodUsageISO8601.date(from: point.at).map { ($0, point.percent) } }
        VStack(spacing: 2) {
            Canvas { context, size in
                guard let start = spans.first?.start, let end = spans.last?.end, end > start else { return }
                let total = spans.reduce(0) { $0 + $1.duration }
                let top = max(live.budget, live.projected, live.used, 1) * 1.1
                let x = { (date: Date) in CGFloat(date.timeIntervalSince(start) / end.timeIntervalSince(start)) * size.width }
                let y = { (value: Double) in size.height - CGFloat(min(value / top, 1.05)) * size.height }
                let now = Date()

                for (index, span) in spans.enumerated().dropFirst() {
                    let gap = CGRect(x: x(spans[index - 1].end), y: 0, width: x(span.start) - x(spans[index - 1].end), height: size.height)
                    context.fill(Path(gap), with: .color(.secondary.opacity(0.12)))
                }
                var budgetLine = Path()
                budgetLine.move(to: CGPoint(x: 0, y: y(live.budget)))
                budgetLine.addLine(to: CGPoint(x: size.width, y: y(live.budget)))
                context.stroke(budgetLine, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                var ideal = Path()
                ideal.move(to: CGPoint(x: 0, y: size.height))
                for step in stride(from: 0.0, through: end.timeIntervalSince(start), by: 300) {
                    let date = start.addingTimeInterval(step)
                    ideal.addLine(to: CGPoint(x: x(date), y: y(live.budget * LivePace.overlap(spans, until: date) / total)))
                }
                context.stroke(ideal, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                var actual = Path()
                actual.move(to: CGPoint(x: 0, y: size.height))
                for (date, percent) in points where date >= start {
                    actual.addLine(to: CGPoint(x: x(min(date, end)), y: y(percent)))
                }
                let nowX = x(min(max(now, start), end))
                actual.addLine(to: CGPoint(x: nowX, y: y(live.used)))
                context.stroke(actual, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                if live.state.isWorking {
                    var projection = Path()
                    projection.move(to: CGPoint(x: nowX, y: y(live.used)))
                    for step in stride(from: 0.0, through: max(0, end.timeIntervalSince(now)), by: 300) {
                        let date = now.addingTimeInterval(step)
                        let worked = LivePace.overlap(spans, until: date) - live.workedSoFar
                        projection.addLine(to: CGPoint(x: x(date), y: y(live.used + (live.rate ?? 0) * worked / 3600)))
                    }
                    context.stroke(projection, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                    let dot = CGRect(x: nowX - 3.5, y: y(live.used) - 3.5, width: 7, height: 7)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                }
                if let runsOutAt = live.runsOutAt {
                    let mark = CGRect(x: x(runsOutAt) - 3, y: y(live.budget) - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: mark), with: .color(Theme.noticeColor))
                }
            }
            HStack {
                Text(spans.first.map { LivePaceFormat.time($0.start) } ?? "")
                Spacer()
                if let runsOutAt = live.runsOutAt {
                    Text("budget ends \(LivePaceFormat.time(runsOutAt))").foregroundStyle(Theme.notice)
                    Spacer()
                }
                Text(spans.last.map { LivePaceFormat.time($0.end) } ?? "")
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: \(LivePaceFormat.percent(live.used)) of \(LivePaceFormat.percent(live.budget)), at this pace \(LivePaceFormat.percent(live.projected)) by the end of the day")
    }
}
