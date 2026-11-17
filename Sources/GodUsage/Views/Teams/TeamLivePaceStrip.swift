import SwiftUI

/// One plan in This Week's Limit with Live Pace on: a pill saying how far ahead of or under today's
/// pace you are, today's bar against its budget with a tick where today's use should be now, the
/// week's boxes, and Details with the pace now and the pace that lasts the day, the working hours, and
/// the day chart. The words and shapes come from `LivePaceDisplay` and `LivePaceDetails`.
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
    /// A plan that's fine opens its week here; view state only, never saved.
    @State private var showsWeek = false
    private var color: Color { TotalSpendPalette.color(for: plan.provider) }
    private var collapsible: Bool { LivePaceDisplay.collapses(live.state) }
    private var expanded: Bool { !collapsible || showsWeek }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeamPlanTitle(teamID: teamID, plan: plan, budget: budget) { pill }
            todayBar
            if expanded {
                TeamWeekBoxes(
                    boxes: WeekBox.boxes(
                        days: budget.days, today: today, used: live.used, budget: live.budget,
                        future: live.futureDays, labelsLowered: live.state == .overBudget
                    ),
                    color: color
                )
                .transition(.opacity)
                details
            }
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
        let budget = LivePaceFormat.percent(live.budget)
        let duration = LivePaceFormat.duration(live.ahead ?? 0)
        switch live.state {
        case .ahead, .onPace, .behind, .warmingUp:
            let ahead = live.ahead ?? 0
            let used = LivePaceFormat.percent(live.used), expected = LivePaceFormat.percent(live.expected)
            let projected = LivePaceFormat.percent(live.projected)
            // Whole sentences, joined with spaces.
            var sentences = [
                abs(ahead) < LivePace.onPaceMargin
                    ? String(localized: "You’re right on pace.")
                    : ahead > 0
                        ? String(localized: "You’re \(duration) ahead of pace: you’ve already used what an even pace would reach only in \(duration) more of working time.")
                        : String(localized: "You’re \(duration) under pace: an even pace would have reached your use \(duration) of working time ago, so you have room to spare."),
                live.end.map {
                    String(localized: "An even pace spreads today’s budget (\(budget)) over the working hours until \(LivePaceFormat.time($0)).")
                } ?? String(localized: "An even pace spreads today’s budget (\(budget)) over the working hours."),
                String(localized: "Now \(used), expected \(expected) (the dark tick on today’s bar).", comment: "Today's use now and the use an even pace expects now."),
            ]
            if useThisNow { sentences.append(String(localized: "Another provider’s plan is running hot: this one has room.")) }
            if live.state == .warmingUp { sentences.append(String(localized: "It’s too early in the day to color it.")) }
            if ahead >= LivePace.onPaceMargin, [.behind, .onPace].contains(live.state) {
                sentences.append(String(localized: "At the current pace, though, you’ll end the day at \(projected), under the budget."))
            } else if ahead <= -LivePace.onPaceMargin, live.state == .ahead {
                sentences.append(String(localized: "At the current pace, though, you’ll end the day at \(projected), over the budget."))
            }
            return sentences.joined(separator: " ")
        case .overBudget:
            let over = LivePaceFormat.percent(live.used - live.budget)
            return String(localized: "Today’s budget is used up: \(over) over. The working days until the reset get less.")
        case .notStarted:
            return String(localized: "Your working day hasn’t started yet. Today’s budget is \(budget).")
        case .dayDone:
            return String(localized: "Your working day is over. What today left, or took over its budget, moves to the working days until the reset.")
        case .dayOff:
            return String(localized: "No working hours today: the weekly limit is spread over the working days until the reset.")
        }
    }

    // MARK: - Today

    /// Today's use against its budget, and the one thing to know next.
    private var todayBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            TeamTodayBar(geometry: TodayBarGeometry(live), color: color)
            HStack(spacing: 6) {
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
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if expanded, let note = LivePaceDisplay.note(live) {
                Text(note.text)
                    .font(.caption2)
                    .foregroundStyle(noteStyle(note.style))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var usedToday: Text {
        Text(LivePaceFormat.percent(live.used)).fontWeight(.semibold).foregroundStyle(.primary)
    }

    /// "› Week": opens the week's boxes and Details of a plan that's fine.
    private var weekToggle: some View {
        Button {
            withAnimation(Motion.spring) { showsWeek.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showsWeek ? 90 : 0))
                Text("Week").font(.caption2.weight(.semibold))
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
            .accessibilityLabel(showsDetails ? Text("Hide Details") : Text("Show Details"))
            Spacer(minLength: 4)
            if let summary = LivePaceDisplay.futureSummary(live) {
                Text("\(summary.days): \(summary.planned) → \(Text(summary.budget).fontWeight(.semibold).foregroundStyle(WeekLimitColors.noticeText))", comment: "The working days left: their planned budget, then the lowered one.")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("\(summary.days) drop from \(summary.planned) to \(summary.budget) a day", comment: "The working days left: their planned budget, then the lowered one."))
            }
        }
        if showsDetails {
            VStack(alignment: .leading, spacing: 8) {
                if let rates = LivePaceDetails.rates(live) {
                    LivePaceRateTiles(now: rates.now, nowTone: LivePaceDetails.paceNowTone(live), allowed: rates.allowed, until: rates.until)
                }
                LivePaceHoursLine(spans: pace.hours.compactMap(\.interval), sharedWith: pace.sharedWith)
                if !pace.hours.isEmpty {
                    LivePaceDayChart(pace: pace, live: live, color: color)
                }
            }
            .padding(.top, 2)
            .transition(.opacity)
        }
    }
}
