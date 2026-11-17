import SwiftUI

/// One plan in This Week's Limit with Live Pace on: a pill saying how far ahead of or under today's
/// pace you are, today's bar against its budget with a tick where today's use should be now, the
/// week's boxes, and Details with the pace that fits the rest of the day, the working hours, and the
/// day chart. The words and shapes come from `LivePaceDisplay`.
struct TeamLivePaceStrip: View {
    let teamID: String
    let plan: TeamPlanReport
    let budget: TeamPlanBudget
    let pace: TeamPlanPace
    let live: LivePace
    /// Another plan is running hot and this one has room: say so on this one.
    let useThisNow: Bool
    let today: String

    @State private var showsDetails = false
    private var color: Color { TotalSpendPalette.color(for: plan.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeamPlanTitle(teamID: teamID, plan: plan, budget: budget) { pill }
            todayBar
            TeamWeekBoxes(
                boxes: WeekBox.boxes(
                    days: budget.days, today: today, used: live.used, budget: live.budget,
                    future: live.futureDays, labelsLowered: live.state == .overBudget
                ),
                color: color
            )
            details
        }
    }

    // MARK: - Pill

    private var pill: some View {
        let (text, style) = LivePaceDisplay.pill(live, useThisNow: useThisNow)
        let (foreground, background): (Color, Color) = switch style {
        case .hot: (WeekLimitColors.noticeText, Theme.noticeColor.opacity(0.16))
        case .cool: (WeekLimitColors.positiveText, Color(nsColor: .systemGreen).opacity(0.16))
        case .neutral: (.primary, Color.secondary.opacity(0.14))
        case .over: (.white, WeekLimitColors.over)
        case .muted: (.secondary, Color.secondary.opacity(0.12))
        }
        return Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule())
            .fixedSize()
            .hoverTooltip(pillTooltip)
            .accessibilityLabel(text)
            .accessibilityHint(pillTooltip)
    }

    /// What the pill means, in words: the minutes are working time against the pace that uses
    /// exactly today's budget by the end of the working day.
    private var pillTooltip: String {
        let end = live.end.map { " until \(LivePaceFormat.time($0))" } ?? ""
        let even = "An even pace spreads today’s budget (\(LivePaceFormat.percent(live.budget))) over the working hours\(end)."
        let duration = LivePaceFormat.duration(live.ahead ?? 0)
        switch live.state {
        case .ahead, .onPace, .behind, .warmingUp:
            let ahead = live.ahead ?? 0
            var text = abs(ahead) < LivePace.onPaceMargin
                ? "You’re right on pace."
                : ahead > 0
                    ? "You’re \(duration) ahead of pace: you’ve already used what an even pace would reach only in \(duration) more of working time."
                    : "You’re \(duration) under pace: an even pace would have reached your use \(duration) of working time ago, so you have room to spare."
            text += " \(even) Now \(LivePaceFormat.percent(live.used)), expected \(LivePaceFormat.percent(live.expected)) (the dark tick on today’s bar)."
            if useThisNow { text += " Another provider’s plan is running hot: this one has room." }
            if live.state == .warmingUp { text += " It’s too early in the day to color it." }
            if ahead >= LivePace.onPaceMargin, [.behind, .onPace].contains(live.state) {
                text += " At the current pace, though, you’ll end the day at \(LivePaceFormat.percent(live.projected)), under the budget."
            } else if ahead <= -LivePace.onPaceMargin, live.state == .ahead {
                text += " At the current pace, though, you’ll end the day at \(LivePaceFormat.percent(live.projected)), over the budget."
            }
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

    // MARK: - Today

    /// Today's use against its budget, and the one thing to know next.
    private var todayBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            TeamTodayBar(geometry: TodayBarGeometry(live), color: color)
            HStack(spacing: 6) {
                (Text(LivePaceFormat.percent(live.used)).fontWeight(.semibold).foregroundStyle(.primary) + Text(" used today"))
                Spacer(minLength: 4)
                Text("budget \(LivePaceFormat.percent(live.budget))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if let note = LivePaceDisplay.note(live) {
                Text(note.text)
                    .font(.caption2)
                    .foregroundStyle(noteStyle(note.style))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func noteStyle(_ style: LivePaceDisplay.NoteStyle) -> AnyShapeStyle {
        switch style {
        case .notice: AnyShapeStyle(WeekLimitColors.noticeText)
        case .positive: AnyShapeStyle(WeekLimitColors.positiveText)
        case .secondary: AnyShapeStyle(.secondary)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var details: some View {
        HStack(spacing: 6) {
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
            Spacer(minLength: 4)
            if let summary = LivePaceDisplay.futureSummary(live) {
                (Text("\(summary.days): \(summary.planned) → ") + Text(summary.budget).fontWeight(.semibold).foregroundStyle(WeekLimitColors.noticeText))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("\(summary.days) drop from \(summary.planned) to \(summary.budget) a day")
            }
        }
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
