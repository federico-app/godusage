import SwiftUI

/// This Week's Limit: for each of the team's plans with an open weekly limit, how much of the week
/// its accounts used, today's use against what today can afford (what was left at the start of today,
/// spread over the working days until the reset), and when the limit resets. A claimed limit reset
/// adds a line with the week's use against its larger capacity. Computed by the server; the phone
/// shows no Live Pace.
struct TeamWeekLimitSection: View {
    let plans: TeamPlans

    var body: some View {
        Section("This Week's Limit") {
            ForEach(plans.weekly, id: \.plan.id) { entry in
                TeamWeekLimitRow(plan: entry.plan, budget: entry.budget)
            }
        }
    }
}

private struct TeamWeekLimitRow: View {
    let plan: TeamPlans.Plan
    let budget: TeamPlans.Budget

    private var isOverBudget: Bool { budget.todayPercent > budget.affordablePercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: plan.name)
                Spacer()
                Text("\(TeamsFormat.percent(budget.weekPercent)) used", comment: "The share of the weekly limit used so far, e.g. 62% used")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(budget.weekPercent, 0), 100), total: 100)
                .tint(budget.weekPercent >= 90 ? .orange : .accentColor)
            if let week = budget.week {
                Text(Self.weekLine(week))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(note)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isOverBudget ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "8% of 14% today · resets Wed 10:00".
    private var note: String {
        let today = TeamsFormat.percent(budget.todayPercent)
        let affordable = TeamsFormat.percent(budget.affordablePercent)
        let reset = TeamsFormat.instant(budget.resetsAt).map(TeamsFormat.weekdayTime) ?? budget.resetsAt
        return String(
            localized: "\(today) of \(affordable) today · resets \(reset)",
            comment: "Today's use of the weekly limit against today's budget, then when the limit resets, e.g. 8% of 14% today · resets Wed 10:00"
        )
    }

    /// "↻ 95% + 40% of 200% this week": a week with a claimed reset holds another limit per claim.
    static func weekLine(_ week: TeamPlans.WeekCapacity) -> String {
        let mark = "↻"
        let used = if let segments = week.segments, segments.count > 1 {
            segments.map(TeamsFormat.percent).joined(separator: " + ")
        } else {
            TeamsFormat.percent(week.usedPercent)
        }
        let capacity = TeamsFormat.percent(week.capacityPercent)
        return String(
            localized: "\(mark) \(used) of \(capacity) this week",
            comment: "A week with a claimed limit reset: the use (each stretch between resets, added up), then the week's capacity, e.g. ↻ 95% + 40% of 200% this week"
        )
    }
}
