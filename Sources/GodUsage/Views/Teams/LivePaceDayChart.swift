import SwiftUI

<<<<<<< HEAD
/// Today over the working hours, every line labeled where it ends: the budget, the even pace to it
/// (dashed), the use so far (solid) with the area between them tinted, and where the current pace
/// leads (dotted), down to the moment it crosses the budget. A rule marks now; the breaks are shaded.
/// The words' positions come from `LivePaceChartLayout`.
=======
/// Today over the working hours: the ideal pace to the budget (dashed), the use so far (solid), and
/// where the current pace leads (dotted), with the breaks shaded.
>>>>>>> origin/main
struct LivePaceDayChart: View {
    let pace: TeamPlanPace
    let live: LivePace
    let color: Color
<<<<<<< HEAD
    /// Where the now rule goes; the strip is rebuilt as the clock moves.
    var now = Date()

    private static let labelFont = Font.system(size: 9).monospacedDigit()
    private static let labelHeight: CGFloat = 11
    private static let breakRow: CGFloat = 12
    private static let axisRow: CGFloat = 13

    private var hasCrossing: Bool { LivePaceChartLayout.crossing(live, width: 1) != nil }

    /// The current pace's color: orange running hot, green well under, else the plan's.
    private var projectionColor: Color {
        switch live.tone {
        case .hot: Theme.noticeColor
        case .cool: Color(nsColor: .systemGreen)
        case .neutral: color
        }
    }

    private var projectionText: Color {
        switch live.tone {
        case .hot: WeekLimitColors.noticeText
        case .cool: WeekLimitColors.positiveText
        case .neutral: .secondary
        }
    }

    var body: some View {
        Canvas { context, size in draw(in: &context, size: size) }
            .frame(height: 104 + (hasCrossing ? Self.axisRow : 0))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LivePaceDetails.chartSummary(live))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let spans = pace.hours.compactMap(\.interval)
        guard let start = spans.first?.start, let end = spans.last?.end, end > start else { return }
        let width = size.width
        let rows = Self.axisRow * (hasCrossing ? 2 : 1)
        let plotTop = Self.breakRow
        let plotBottom = size.height - rows - 3
        let total = spans.reduce(0) { $0 + $1.duration }
        let top = max(live.budget, live.projected, live.used, 1) * 1.1
        let x = { (date: Date) in LivePaceChartLayout.x(date, start: start, end: end, width: width) }
        let y = { (value: Double) in plotBottom - CGFloat(min(max(value, 0) / top, 1.05)) * (plotBottom - plotTop) }
        let ideal = { (date: Date) in live.budget * LivePace.overlap(spans, until: date) / total }
        let working = live.state.isWorking && now >= start && now <= end
        let nowX = x(min(max(now, start), end))
        func label(_ text: String, _ style: Color, weight: Font.Weight = .regular) -> GraphicsContext.ResolvedText {
            context.resolve(Text(text).font(Self.labelFont.weight(weight)).foregroundStyle(style))
        }

        // Breaks, labeled at the top.
        for (index, span) in spans.enumerated().dropFirst() {
            let from = x(spans[index - 1].end), to = x(span.start)
            context.fill(Path(CGRect(x: from, y: plotTop, width: to - from, height: plotBottom - plotTop)), with: .color(.secondary.opacity(0.12)))
            let text = label("Break", .secondary)
            if text.measure(in: size).width <= to - from + 16 {
                context.draw(text, at: CGPoint(x: (from + to) / 2, y: plotTop - 1), anchor: .bottom)
            }
        }

        // The axis and the budget.
        context.stroke(line(from: CGPoint(x: 0, y: plotBottom), to: CGPoint(x: width, y: plotBottom)), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        context.stroke(line(from: CGPoint(x: 0, y: y(live.budget)), to: CGPoint(x: width, y: y(live.budget))), with: .color(.secondary.opacity(0.45)), lineWidth: 1)

        // Today's use so far, and the even pace over the whole day.
        let samples = pace.today.compactMap { point in GodUsageISO8601.date(from: point.at).map { ($0, point.percent) } }
        var usePoints = [CGPoint(x: 0, y: plotBottom)]
        for (date, percent) in samples where date >= start && date <= min(now, end) {
            usePoints.append(CGPoint(x: x(date), y: y(percent)))
        }
        usePoints.append(CGPoint(x: nowX, y: y(live.used)))
        let idealPoints = stride(from: 0.0, through: end.timeIntervalSince(start), by: 300).map { step in
            let date = start.addingTimeInterval(step)
            return CGPoint(x: x(date), y: y(ideal(date)))
        } + [CGPoint(x: width, y: y(live.budget))]

        // The gap between them up to now: orange ahead, green behind.
        if working, let shade = LivePaceDetails.shade(live) {
            let idealToNow = idealPoints.filter { $0.x < nowX } + [CGPoint(x: nowX, y: y(ideal(now)))]
            var area = Path()
            area.addLines(usePoints + idealToNow.reversed())
            area.closeSubpath()
            let tint = shade == .ahead ? Theme.noticeColor : Color(nsColor: .systemGreen)
            context.fill(area, with: .color(tint.opacity(0.18)))
        }

        var idealPath = Path()
        idealPath.addLines(idealPoints)
        context.stroke(idealPath, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))

        var usePath = Path()
        usePath.addLines(usePoints)
        context.stroke(usePath, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // Where the current pace leads, and where it crosses the budget.
        var projectedEnd: Double?
        if working {
            var projection = Path()
            projection.move(to: CGPoint(x: nowX, y: y(live.used)))
            var value = live.used
            for step in stride(from: 0.0, through: max(0, end.timeIntervalSince(now)), by: 300) {
                let date = now.addingTimeInterval(step)
                value = live.used + (live.rate ?? 0) * (LivePace.overlap(spans, until: date) - live.workedSoFar) / 3600
                projection.addLine(to: CGPoint(x: x(date), y: y(value)))
            }
            value = live.projected
            projection.addLine(to: CGPoint(x: width, y: y(value)))
            projectedEnd = value
            context.stroke(projection, with: .color(projectionColor), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [1, 3]))
        }

        // Now: a rule down to the axis and today's use on it.
        if working {
            context.stroke(line(from: CGPoint(x: nowX, y: plotTop), to: CGPoint(x: nowX, y: plotBottom)), with: .color(.primary.opacity(0.8)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: nowX - 3.5, y: y(live.used) - 3.5, width: 7, height: 7)), with: .color(color))
        }

        let crossX = LivePaceChartLayout.crossing(live, width: width)
        if let crossX {
            let point = CGPoint(x: crossX, y: y(live.budget))
            context.stroke(line(from: point, to: CGPoint(x: crossX, y: plotBottom)), with: .color(projectionColor), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let ring = Path(ellipseIn: CGRect(x: crossX - 3.5, y: point.y - 3.5, width: 7, height: 7))
            context.fill(ring, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(ring, with: .color(projectionColor), lineWidth: 1.75)
        }

        // The lines' names at their right ends, nudged apart when they'd overlap.
        var names: [(text: GraphicsContext.ResolvedText, center: CGFloat)] = [
            (label("Budget \(LivePaceFormat.percent(live.budget))", .secondary), y(live.budget) - 7),
            (label("Even pace", .secondary), y(live.budget) + 7),
        ]
        if let projectedEnd {
            let endY = y(projectedEnd)
            names.append((label("At this pace", projectionText), projectedEnd >= live.budget ? endY - 7 : endY + 7))
        }
        let centers = LivePaceChartLayout.nudge(names.map(\.center), height: Self.labelHeight, within: 0...plotBottom)
        for (name, center) in zip(names, centers) {
            context.draw(name.text, at: CGPoint(x: width - 2, y: center), anchor: .trailing)
        }

        // Under the axis: the day's start and end, now, and when the budget runs out.
        let rowY = plotBottom + 3
        let nowLabel = working ? label("Now \(LivePaceFormat.time(now))", .primary, weight: .semibold) : nil
        let nowWidth = nowLabel?.measure(in: size).width ?? 0
        let nowCenter = LivePaceChartLayout.clampedCenter(nowX, labelWidth: nowWidth, in: width)
        let startLabel = label(LivePaceFormat.time(start), .secondary)
        let endLabel = label(LivePaceFormat.time(end), .secondary)
        let startWidth = startLabel.measure(in: size).width, endWidth = endLabel.measure(in: size).width
        if nowLabel == nil || !LivePaceChartLayout.overlap((nowCenter, nowWidth), (startWidth / 2, startWidth)) {
            context.draw(startLabel, at: CGPoint(x: 0, y: rowY), anchor: .topLeading)
        }
        if nowLabel == nil || !LivePaceChartLayout.overlap((nowCenter, nowWidth), (width - endWidth / 2, endWidth)) {
            context.draw(endLabel, at: CGPoint(x: width, y: rowY), anchor: .topTrailing)
        }
        if let nowLabel {
            context.draw(nowLabel, at: CGPoint(x: nowCenter, y: rowY), anchor: .top)
        }
        if let crossX, let runsOutAt = live.runsOutAt {
            let text = label("Budget ends \(LivePaceFormat.time(runsOutAt))", projectionText, weight: .semibold)
            let center = LivePaceChartLayout.clampedCenter(crossX, labelWidth: text.measure(in: size).width, in: width)
            context.draw(text, at: CGPoint(x: center, y: rowY + Self.axisRow), anchor: .top)
        }
    }

    private func line(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
=======

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
>>>>>>> origin/main
    }
}
