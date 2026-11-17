import SwiftUI

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
