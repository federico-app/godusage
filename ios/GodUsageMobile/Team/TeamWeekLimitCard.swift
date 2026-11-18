import SwiftUI

/// This Week's Limit, as on the Mac's panel: for each of the team's plans with an open weekly limit,
/// Live Pace when the server sends a pace (the pill, today's bar with a tick where today's use should
/// be now, and the week behind "Week"), else today's use against today's budget with the week's boxes.
/// Live Pace moves with the clock, so the card redraws every minute.
struct TeamWeekLimitCard: View {
    var model: TeamsModel
    let teamID: String
    let plans: TeamPlans

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let today = TeamsFormat.localToday(now)
            let rows = plans.weekly
            let paces = rows.compactMap { entry in model.livePace(teamID: teamID, plan: entry.plan, now: now).map { (plan: entry.plan, live: $0) } }
            let roomFor = LivePaceDisplay.useThisNow(paces)
            VStack(alignment: .leading, spacing: 12) {
                Text("This Week's Limit")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.element.plan.id) { index, entry in
                    if index > 0 { Divider() }
                    if let live = paces.first(where: { $0.plan.id == entry.plan.id })?.live {
                        LivePacePlanRow(
                            plan: entry.plan, budget: entry.budget, live: live, useThisNow: roomFor.contains(entry.plan.id), today: today
                        )
                    } else {
                        WeekPlanRow(plan: entry.plan, budget: entry.budget, today: today, showsNote: rows.count < 3)
                    }
                }
            }
            .task(id: now) { model.rememberPaces(teamID: teamID, now: now) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// One plan with Live Pace: the pill, today's bar, "X of Y today" and "› Week" for a plan that's
/// fine; a plan ahead of pace or at or over today's budget shows its week and note right away.
private struct LivePacePlanRow: View {
    let plan: TeamPlans.Plan
    let budget: TeamPlans.Budget
    let live: LivePace
    let useThisNow: Bool
    let today: String

    @State private var showsWeek = false
    private var color: Color { ProviderPalette.color(for: plan.provider) }
    private var collapsible: Bool { LivePaceDisplay.collapses(live.state) }
    private var expanded: Bool { !collapsible || showsWeek }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlanTitle(plan: plan, budget: budget) { pill }
            VStack(alignment: .leading, spacing: 4) {
                TodayBar(geometry: TodayBarGeometry(live), color: color)
                HStack(spacing: 6) {
                    let usedToday = Text(LivePaceFormat.percent(live.used)).fontWeight(.semibold).foregroundStyle(.primary)
                    if collapsible {
                        Text("\(usedToday) of \(LivePaceFormat.percent(live.budget)) today", comment: "Today's use, bold, against today's budget.")
                        Spacer(minLength: 4)
                        weekToggle
                    } else {
                        Text("\(usedToday) used today", comment: "Today's use, bold.")
                        Spacer(minLength: 4)
                        Text("budget \(LivePaceFormat.percent(live.budget))", comment: "Today's budget, as a share of the weekly limit.")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if expanded, let note = LivePaceDisplay.note(live) {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(noteStyle(note.style))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if expanded, let days = budget.days, !days.isEmpty {
                WeekBoxesView(
                    boxes: WeekBox.boxes(
                        days: days, today: today, used: live.shownUsed, budget: live.budget,
                        future: live.futureDays, labelsLowered: live.state == .overBudget
                    ),
                    color: color
                )
                .transition(.opacity)
            }
        }
    }

    private var pill: some View {
        let (text, style) = LivePaceDisplay.pill(live, useThisNow: useThisNow)
        let (foreground, background): (Color, Color) = switch style {
        case .hot: (WeekLimitColors.noticeText, Color.orange.opacity(0.16))
        case .cool: (WeekLimitColors.positiveText, Color.green.opacity(0.16))
        case .neutral: (.primary, Color.secondary.opacity(0.14))
        case .over: (.white, WeekLimitColors.over)
        case .muted: (.secondary, Color.secondary.opacity(0.12))
        }
        return Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var weekToggle: some View {
        Button {
            withAnimation(.snappy) { showsWeek.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showsWeek ? 90 : 0))
                Text("Week").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsWeek ? Text("Hide Week") : Text("Show Week"))
    }

    private func noteStyle(_ style: LivePaceDisplay.NoteStyle) -> AnyShapeStyle {
        switch style {
        case .notice: AnyShapeStyle(WeekLimitColors.noticeText)
        case .positive: AnyShapeStyle(WeekLimitColors.positiveText)
        case .secondary: AnyShapeStyle(.secondary)
        }
    }
}

/// One plan without Live Pace: today's use against today's budget, the week's boxes, and a line with
/// what's left today and when the limit resets.
private struct WeekPlanRow: View {
    let plan: TeamPlans.Plan
    let budget: TeamPlans.Budget
    let today: String
    let showsNote: Bool

    private var overBudget: Bool { budget.todayPercent > budget.affordablePercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlanTitle(plan: plan, budget: budget) { figure }
            if let days = budget.days, !days.isEmpty {
                WeekBoxesView(boxes: WeekBox.boxes(budget, today: today), color: ProviderPalette.color(for: plan.provider))
            } else {
                TodayBar(geometry: TodayBarGeometry(used: budget.todayPercent, budget: budget.affordablePercent, expected: nil), color: ProviderPalette.color(for: plan.provider))
            }
            if showsNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(overBudget ? AnyShapeStyle(WeekLimitColors.noticeText) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var figure: some View {
        let used = Text(LivePaceFormat.percent(budget.todayPercent))
            .fontWeight(.semibold)
            .foregroundStyle(overBudget ? AnyShapeStyle(WeekLimitColors.noticeText) : AnyShapeStyle(.primary))
        return Text("\(used) of \(LivePaceFormat.percent(budget.affordablePercent)) today", comment: "Today's use, bold, against today's budget.")
            .foregroundStyle(.secondary)
            .font(.caption.monospacedDigit())
            .fixedSize()
    }

    private var note: String {
        let reset = TeamsFormat.instant(budget.resetsAt).map(TeamsFormat.weekdayTime) ?? budget.resetsAt
        if overBudget {
            let over = LivePaceFormat.percent(budget.todayPercent - budget.affordablePercent)
            return String(localized: "\(over) over today's budget · resets \(reset)", comment: "Points over today's budget; when the weekly limit resets.")
        }
        let left = LivePaceFormat.percent(budget.affordablePercent - budget.todayPercent)
        return String(localized: "\(left) more today on budget · resets \(reset)", comment: "Points left in today's budget; when the weekly limit resets.")
    }
}
