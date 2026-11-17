import SwiftUI

/// Under a plan in the Plans tab, collapsed until opened: its last weekly windows (reset to reset), one
/// row each, with the share of the weekly limit used each day (darker the more), the window's share,
/// and its 5-hour sessions.
struct TeamPlanWeeklyHistory: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    let plan: TeamPlanReport
    let today: String
    @State private var isExpanded = false

    private var color: Color { TotalSpendPalette.color(for: plan.provider) }
    /// The share per working day that uses exactly the week: a cell this full is fully dark at 1.5×.
    private var pace: Double { plan.daily?.pacePercent ?? 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Weekly History").font(.caption.weight(.semibold))
                    Text("share of the weekly limit used each day").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content }
        }
        .task(id: isExpanded) {
            guard isExpanded, container.teamPlans.history(teamID: teamID) == nil else { return }
            await container.teamPlans.loadHistory(teamID: teamID)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let weeks = container.teamPlans.history(teamID: teamID)?.weeks(for: plan) {
            if weeks.isEmpty {
                Text("No week read yet. Each Mac records the share it sees of the weekly limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                table(weeks.reversed())
                legend(hasResets: weeks.contains { ($0.resets ?? 0) > 0 })
            }
        } else if let error = container.teamPlans.historyError(teamID: teamID) {
            Text(error).font(.caption).foregroundStyle(Theme.notice)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Columns are the days of the window, named after the newest one's; a week that a reset moved
    /// names its own days in its cells.
    private func table(_ weeks: [TeamPlanHistory.Week]) -> some View {
        let columns = weeks.map(\.days.count).max() ?? 7
        let header = weeks.first.map { $0.days.map { Self.weekday($0.day) } } ?? []
        return Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("Week")
                ForEach(0..<columns, id: \.self) { index in
                    Text(index < header.count ? header[index] : "").frame(maxWidth: .infinity)
                }
                Text("Used").gridColumnAlignment(.trailing)
                Text("Sessions").gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(weeks, id: \.endsAt) { week in
                let shifted = week.days.map { Self.weekday($0.day) } != Array(header.prefix(week.days.count))
                GridRow {
                    weekLabel(week)
                    ForEach(0..<columns, id: \.self) { index in
                        if index < week.days.count {
                            cell(week.days[index], showsWeekday: shifted)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 26)
                        }
                    }
                    total(week)
                    sessions(week)
                }
            }
        }
    }

    private func weekLabel(_ week: TeamPlanHistory.Week) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Self.shortDate(week.from)) – \(Self.shortDate(week.to))").font(.caption.weight(.semibold))
            if week.accounts > 1 {
                Text("\(week.accounts) accounts").font(.caption2).foregroundStyle(Color.accentColor)
            } else if week.open {
                Text("this week").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    private func cell(_ day: TeamPlanHistory.Day, showsWeekday: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return ZStack(alignment: showsWeekday ? .topLeading : .center) {
            if let percent = day.percent {
                shape.fill(color.opacity(day.estimated ? 0.25 : 0.12 + 0.88 * min(percent / (pace * 1.5), 1)))
                if day.estimated { shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                if day.day == today { shape.strokeBorder(color, lineWidth: 1.5) }
                Text((day.estimated ? "~" : "") + Self.number(percent))
            } else if day.day > today {
                Color.clear
            } else if !day.working {
                shape.fill(Color.secondary.opacity(0.1))
                Text("off").foregroundStyle(.secondary)
            } else {
                shape.strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Text("·").foregroundStyle(.secondary)
            }
            if showsWeekday {
                Text(Self.weekday(day.day)).font(.system(size: 8)).foregroundStyle(.secondary).padding(2)
            }
            if (day.resets ?? 0) > 0 {
                Text(ResetCapacityFormat.mark).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(2)
            }
        }
        .font(.caption2.monospacedDigit().weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 26)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(Self.weekday(day.day)) \(day.day): \(Self.reading(day))"
            + ((day.resets ?? 0) > 0 ? ", " + String(localized: "reset claimed", comment: "A day on which a limit reset was claimed.") : "")))
    }

    /// The window's share; after a claimed reset, its use against its capacity ("135%" over "of 200% ↻").
    private func total(_ week: TeamPlanHistory.Week) -> some View {
        let reached = week.percent >= 100
        let capacity = week.capacityPercent.flatMap { $0 > 100 ? $0 : nil }
        return VStack(alignment: .trailing, spacing: 0) {
            Text((week.estimated ? "~" : "") + Self.number(capacity == nil ? week.percent : week.usedPercent ?? week.percent) + "%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(reached ? Theme.notice : AnyShapeStyle(.primary))
            if let capacity {
                Text("of \(Self.number(capacity))% \(ResetCapacityFormat.mark)", comment: "Under a week's use in Weekly History: the week's capacity after a claimed limit reset, e.g. of 200% ↻")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if reached || week.open {
                Text(reached ? "limit reached" : "so far").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 70, alignment: .trailing)
    }

    private func sessions(_ week: TeamPlanHistory.Week) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let sessions = week.sessions {
                Text("\(sessions.limitHits) of \(sessions.sessions) hit")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(sessions.limitHits > 0 ? Theme.notice : AnyShapeStyle(.primary))
                Text("avg peak \(Self.number(sessions.averagePeakPercent))%").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 90, alignment: .trailing)
    }

    private func legend(hasResets: Bool) -> some View {
        HStack(spacing: 12) {
            Label { Text("darker = more") } icon: { RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 10, height: 10) }
            Label { Text("~ estimated") } icon: {
                RoundedRectangle(cornerRadius: 2).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1])).frame(width: 10, height: 10)
            }
            Label { Text("· no reading") } icon: {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 1])).frame(width: 10, height: 10)
            }
            if hasResets { Text("\(ResetCapacityFormat.mark) reset claimed", comment: "Weekly History legend: a limit reset was claimed that day; the week counts against one more limit.") }
            Text("Used: the window's share of the weekly limit")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// One decimal, like Per Day; whole numbers without it.
    static func number(_ value: Double) -> String {
        AppLocale.decimal(value, digits: value.rounded() == value ? 0 : 1)
    }

    /// A day's reading for VoiceOver: "19.5%", "about 19.5%", "no reading".
    private static func reading(_ day: TeamPlanHistory.Day) -> String {
        guard let percent = day.percent else { return String(localized: "no reading", comment: "A day with no usage reading") }
        let value = number(percent)
        return day.estimated ? String(localized: "about \(value)%", comment: "An estimated percentage, e.g. about 19.5%") : value + "%"
    }

    private static func weekday(_ day: String) -> String {
        guard let date = TeamsFormat.date(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(AppLocale.current))
    }

    private static func shortDate(_ day: String) -> String {
        guard let date = TeamsFormat.date(day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(AppLocale.current))
    }

}
