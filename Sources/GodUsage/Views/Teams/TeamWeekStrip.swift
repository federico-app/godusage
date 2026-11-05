import SwiftUI

/// In the dashboard's Team section, above the ranking: for each plan with an open weekly limit, its
/// week so far, one bar per day, with today's use against what today can afford (what's left of the
/// week spread over the working days until the reset) and the days left drawn at that budget. Plans
/// from your other teams (see `YourTeamPlans`) name their team.
struct TeamWeekStripCard: View {
    let plans: [TeamPlanEntry]
    /// The team a row names; nil for the selected team's own plans.
    let teamName: (String) -> String?
    let today: String

    private var budgeted: [(TeamPlanEntry, TeamPlanBudget)] {
        plans.compactMap { entry in entry.plan.budget.map { (entry, $0) } }
    }

    var body: some View {
        let rows = budgeted
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("This Week's Limit")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows, id: \.0.id) { entry, budget in
                    // Three plans or more drop the line under each strip to stay short.
                    TeamWeekStrip(
                        plan: entry.plan, budget: budget, today: today, showsNote: rows.count < 3, teamName: teamName(entry.teamID)
                    )
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
    /// Set for a plan from another of your teams.
    var teamName: String?

    private static let height: CGFloat = 40
    private var color: Color { TotalSpendPalette.color(for: plan.provider) }
    private var pace: Double { plan.daily?.pacePercent ?? 20 }
    private var scale: Double {
        max(pace * 1.5, budget.affordablePercent * 1.2, budget.days.compactMap(\.percent).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            bars
            if showsNote {
                Text(Self.note(budget)).font(.caption2).foregroundStyle(overBudget ? Theme.notice : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overBudget: Bool { Self.isOverBudget(budget) }

    /// Nothing in the header is ever cut off: on one line when it fits, else the figure moves under
    /// the name (which may wrap), still right-aligned.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                title.fixedSize()
                Spacer(minLength: 4)
                figure
            }
            VStack(alignment: .leading, spacing: 2) {
                title.fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    figure
                }
            }
        }
    }

    /// The dot, the plan's name, its team when it's from another of yours, and how many accounts it mixes.
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            (Text(plan.name).font(.caption.weight(.semibold))
                + Text(teamName.map { "  \($0)" } ?? "").font(.caption2).foregroundStyle(.secondary))
            if budget.accounts > 1 {
                Text("\(budget.accounts) accounts")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
        }
    }

    private var figure: some View {
        (Text(Self.percent(budget.todayPercent))
            .fontWeight(.semibold)
            .foregroundStyle(overBudget ? Theme.notice : AnyShapeStyle(.primary))
            + Text(" of \(Self.percent(budget.affordablePercent)) today").foregroundStyle(.secondary))
            .font(.caption.monospacedDigit())
            .fixedSize()
    }

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
        return "\(Self.percent(budget.affordablePercent - budget.todayPercent)) more today on budget · resets \(reset)"
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
