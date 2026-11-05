import SwiftUI

/// In the dashboard's Team section, above the ranking: for each plan with an open weekly limit, its
/// week so far, one bar per day, with today's use against what today can afford (what's left of the
/// week spread over the working days until the reset) and the days left drawn at that budget.
struct TeamWeekStripCard: View {
    let plans: [TeamPlanReport]
    let providerName: (String) -> String
    let today: String

    private var budgeted: [(TeamPlanReport, TeamPlanBudget)] {
        plans.compactMap { plan in plan.budget.map { (plan, $0) } }
    }

    var body: some View {
        let rows = budgeted
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("This Week's Limit")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows, id: \.0.id) { plan, budget in
                    // Three plans or more drop the line under each strip to stay short.
                    TeamWeekStrip(plan: plan, budget: budget, today: today, showsNote: rows.count < 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .cardSurface()
        }
    }
}

struct TeamWeekStrip: View {
    let plan: TeamPlanReport
    let budget: TeamPlanBudget
    let today: String
    let showsNote: Bool

    private static let height: CGFloat = 40
    private var color: Color { TotalSpendPalette.color(for: plan.provider) }
    private var pace: Double { plan.daily?.pacePercent ?? 20 }
    private var scale: Double {
        max(pace * 1.5, budget.affordablePercent * 1.2, budget.days.compactMap(\.percent).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(plan.name).font(.caption.weight(.semibold)).lineLimit(1).layoutPriority(1)
                if budget.accounts > 1 {
                    Text("\(budget.accounts) accounts")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 4)
                (Text(Self.percent(budget.todayPercent))
                    .fontWeight(.semibold)
                    .foregroundStyle(overBudget ? Theme.notice : AnyShapeStyle(.primary))
                    + Text(" of \(Self.percent(budget.affordablePercent)) today").foregroundStyle(.secondary))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            }
            bars
            if showsNote {
                Text(Self.note(budget)).font(.caption2).foregroundStyle(overBudget ? Theme.notice : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overBudget: Bool { Self.isOverBudget(budget) }

    static func isOverBudget(_ budget: TeamPlanBudget) -> Bool { budget.todayPercent > budget.affordablePercent }

    private var bars: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(budget.days, id: \.day) { day in bar(day).frame(maxWidth: .infinity) }
            }
            .frame(height: Self.height, alignment: .bottom)
            .overlay(alignment: .bottom) {
                PaceLine()
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 1)
                    .offset(y: -height(pace))
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }
            HStack(spacing: 3) {
                ForEach(budget.days, id: \.day) { day in
                    Text(day.day == today ? "Today" : Self.weekday(day.day))
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
            // Days left: the working ones at today's budget, the rest empty.
            if day.working {
                shape.strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(height: height(budget.affordablePercent))
            } else {
                Color.clear.frame(height: 0)
            }
        } else if day.day == today {
            ZStack(alignment: .bottom) {
                shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: height(budget.affordablePercent))
                shape.fill(color.opacity(0.8)).frame(height: max(height(day.percent ?? 0), 2))
            }
        } else if let percent = day.percent {
            shape.fill(day.estimated ? color.opacity(0.4) : color).frame(height: max(height(percent), 2))
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func height(_ percent: Double) -> CGFloat {
        CGFloat(min(percent / scale, 1)) * Self.height
    }

    static func note(_ budget: TeamPlanBudget) -> String {
        let reset = Self.resetDay(budget.resetsAt)
        if isOverBudget(budget) {
            return "\(Self.percent(budget.todayPercent - budget.affordablePercent)) over today's budget · resets \(reset)"
        }
        return "\(Self.percent(budget.affordablePercent - budget.todayPercent)) more today on budget · \(Self.percent(budget.leftPercent)) left · resets \(reset)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private static func weekday(_ day: String) -> String {
        guard let date = TeamsFormat.date(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private static func resetDay(_ instant: String) -> String {
        guard let date = try? Date(instant, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) else { return instant }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The full-pace line across the strip.
private struct PaceLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
