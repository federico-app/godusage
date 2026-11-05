import SwiftUI

/// Compare → Plan Weeks: two weekly windows of plans side by side, from the same team or from two of
/// yours: each day's share of the weekly limit, the window's share, its busiest day, and its sessions.
/// The two sides are told apart by color and by their pickers, never by a provider color.
struct TeamPlanWeeksCompareView: View {
    @Environment(AppContainer.self) private var container
    let initialTeamID: String?

    @State private var left = Side()
    @State private var right = Side()

    struct Side: Equatable {
        var teamID: String?
        var planKey: String?
        var weekEnd: String?
    }

    static let leftColor = Color(red: 0.18, green: 0.44, blue: 0.84)
    static let rightColor = Color(red: 0.86, green: 0.5, blue: 0.13)

    var body: some View {
        let teams = container.teams.teams
        let leftTeam = left.teamID ?? initialTeamID ?? teams.first?.id
        let rightTeam = right.teamID ?? teams.first { $0.id != leftTeam }?.id ?? leftTeam
        let leftPick = pick(teamID: leftTeam, side: left, skippingNewest: false)
        // Same team and plan on both sides: the right one starts on the week before.
        let rightPick = pick(teamID: rightTeam, side: right, skippingNewest: rightTeam == leftTeam && right.weekEnd == nil)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                picker(binding: $left, teamID: leftTeam, picked: leftPick, color: Self.leftColor)
                Text("vs").font(.headline).foregroundStyle(.secondary).padding(.top, 10)
                picker(binding: $right, teamID: rightTeam, picked: rightPick, color: Self.rightColor)
            }
            if let a = leftPick.week, let b = rightPick.week, let aPlan = leftPick.plan, let bPlan = rightPick.plan {
                HStack(alignment: .top, spacing: 24) {
                    days(a, b).frame(maxWidth: .infinity, alignment: .leading)
                    table(a, b, aName: teamName(leftTeam), bName: teamName(rightTeam))
                        .frame(maxWidth: 360, alignment: .leading)
                }
                Text(Self.summary(a, b, aName: teamName(leftTeam), bName: teamName(rightTeam), samePlan: aPlan.name == bPlan.name))
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Pick a plan with a weekly limit (Claude or Codex) on each side. Weeks show up once a Mac has read them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            }
        }
        .task(id: [leftTeam, rightTeam].compactMap { $0 }) {
            for teamID in Set([leftTeam, rightTeam].compactMap { $0 }) where container.teamPlans.history(teamID: teamID) == nil {
                await container.teamPlans.loadHistory(teamID: teamID)
            }
        }
    }

    private struct Picked {
        var plans: [TeamPlanHistory.Plan] = []
        var plan: TeamPlanHistory.Plan?
        var week: TeamPlanHistory.Week?
    }

    private static func key(_ plan: TeamPlanHistory.Plan) -> String { "\(plan.provider)|\(plan.name)" }

    private func pick(teamID: String?, side: Side, skippingNewest: Bool) -> Picked {
        let plans = (teamID.flatMap { container.teamPlans.history(teamID: $0) }?.plans ?? []).filter { !$0.weeks.isEmpty }
        let plan = plans.first { Self.key($0) == side.planKey } ?? plans.first
        let weeks = plan?.weeks ?? []
        let week = weeks.first { $0.endsAt == side.weekEnd }
            ?? (skippingNewest && weeks.count > 1 ? weeks[weeks.count - 2] : weeks.last)
        return Picked(plans: plans, plan: plan, week: week)
    }

    private func teamName(_ id: String?) -> String {
        container.teams.teams.first { $0.id == id }?.name ?? "Team"
    }

    private func picker(binding: Binding<Side>, teamID: String?, picked: Picked, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Picker("Team", selection: Binding(get: { teamID ?? "" }, set: { binding.wrappedValue = Side(teamID: $0) })) {
                ForEach(container.teams.teams) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            if !picked.plans.isEmpty {
                Picker("Plan", selection: Binding(
                    get: { picked.plan.map(Self.key) ?? "" },
                    set: { binding.wrappedValue = Side(teamID: teamID, planKey: $0) }
                )) {
                    ForEach(picked.plans, id: \.id) { Text($0.name).tag(Self.key($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Week", selection: Binding(
                    get: { picked.week?.endsAt ?? "" },
                    set: { binding.wrappedValue = Side(teamID: teamID, planKey: picked.plan.map(Self.key), weekEnd: $0) }
                )) {
                    ForEach((picked.plan?.weeks ?? []).reversed(), id: \.endsAt) { Text(Self.range($0)).tag($0.endsAt) }
                }
                .labelsHidden()
                .fixedSize()
            } else if container.teamPlans.history(teamID: teamID ?? "") == nil {
                ProgressView().controlSize(.small)
            } else {
                Text("No weekly limit read yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 1.5))
    }

    // MARK: - Days

    private static let chartHeight: CGFloat = 140

    /// Day by day, by position in the window: each window starts at its own reset.
    private func days(_ a: TeamPlanHistory.Week, _ b: TeamPlanHistory.Week) -> some View {
        let count = max(a.days.count, b.days.count)
        let scale = max(30, (a.days + b.days).compactMap(\.percent).max() ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Per Day").font(.caption.weight(.semibold))
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(alignment: .bottom, spacing: 2) {
                        bar(index < a.days.count ? a.days[index] : nil, scale: scale, color: Self.leftColor)
                        bar(index < b.days.count ? b.days[index] : nil, scale: scale, color: Self.rightColor)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(spacing: 1) {
                        label(index < a.days.count ? a.days[index] : nil, color: Self.leftColor)
                        label(index < b.days.count ? b.days[index] : nil, color: Self.rightColor)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func bar(_ day: TeamPlanHistory.Day?, scale: Double, color: Color) -> some View {
        let percent = day?.percent ?? 0
        return UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
            .fill(color.opacity(day?.estimated == true ? 0.45 : 1))
            .frame(height: day?.percent == nil ? 0 : max(CGFloat(min(percent / scale, 1)) * Self.chartHeight, 2))
            .frame(maxWidth: .infinity)
    }

    private func label(_ day: TeamPlanHistory.Day?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let day {
                Text(Self.weekday(day.day)).foregroundStyle(.secondary)
                Text(day.percent.map { (day.estimated ? "~" : "") + TeamPlanWeeklyHistory.number($0) + "%" } ?? "—")
                    .foregroundStyle(color)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: - Table

    private func table(_ a: TeamPlanHistory.Week, _ b: TeamPlanHistory.Week, aName: String, bName: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("The Week").font(.caption.weight(.semibold))
                Text(aName).foregroundStyle(Self.leftColor).gridColumnAlignment(.trailing)
                Text(bName).foregroundStyle(Self.rightColor).gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Self.rows(a, b), id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.left).monospacedDigit()
                    Text(row.right).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    struct Row: Equatable {
        var label: String
        var left: String
        var right: String
    }

    static func rows(_ a: TeamPlanHistory.Week, _ b: TeamPlanHistory.Week) -> [Row] {
        func used(_ week: TeamPlanHistory.Week) -> String {
            (week.estimated ? "~" : "") + TeamPlanWeeklyHistory.number(week.percent) + "%" + (week.open ? " so far" : "")
        }
        func busiest(_ week: TeamPlanHistory.Week) -> String {
            guard let day = week.days.filter({ $0.percent != nil }).max(by: { $0.percent! < $1.percent! }) else { return "—" }
            return "\(weekday(day.day)) · \(TeamPlanWeeklyHistory.number(day.percent!))%"
        }
        func sessions(_ week: TeamPlanHistory.Week) -> String {
            week.sessions.map { "\($0.limitHits) of \($0.sessions)" } ?? "—"
        }
        func peak(_ week: TeamPlanHistory.Week) -> String {
            week.sessions.map { TeamPlanWeeklyHistory.number($0.averagePeakPercent) + "%" } ?? "—"
        }
        return [
            Row(label: "Weekly limit used", left: used(a), right: used(b)),
            Row(label: "Limit reached", left: a.percent >= 100 ? "Yes" : "No", right: b.percent >= 100 ? "Yes" : "No"),
            Row(label: "Busiest day", left: busiest(a), right: busiest(b)),
            Row(label: "Sessions at the limit", left: sessions(a), right: sessions(b)),
            Row(label: "Average session peak", left: peak(a), right: peak(b)),
            Row(label: "Accounts", left: "\(a.accounts)", right: "\(b.accounts)"),
        ]
    }

    /// One line on who used more of their weekly limit, and a warning when the plans differ.
    static func summary(_ a: TeamPlanHistory.Week, _ b: TeamPlanHistory.Week, aName: String, bName: String, samePlan: Bool) -> String {
        let gap = a.percent - b.percent
        var text: String
        if abs(gap) < 0.5 {
            text = "Both used about the same share of their weekly limit."
        } else {
            let (more, less) = gap > 0 ? (aName, bName) : (bName, aName)
            let points = TeamPlanWeeklyHistory.number((abs(gap) * 10).rounded() / 10)
            text = aName == bName
                ? "The \(gap > 0 ? "first" : "second") week used \(points) points more of the weekly limit."
                : "\(more) used \(points) points more of its weekly limit than \(less)."
        }
        if a.open || b.open { text += " One of the weeks is still running." }
        if !samePlan { text += " The plans differ, so the shares are of different limits." }
        return text
    }

    private static func range(_ week: TeamPlanHistory.Week) -> String {
        let from = TeamsFormat.date(week.from)?.formatted(.dateTime.day().month(.abbreviated)) ?? week.from
        let to = TeamsFormat.date(week.to)?.formatted(.dateTime.day().month(.abbreviated)) ?? week.to
        return week.open ? "\(from) – \(to) (this week)" : "\(from) – \(to)"
    }

    private static func weekday(_ day: String) -> String {
        TeamsFormat.date(day)?.formatted(.dateTime.weekday(.abbreviated)) ?? day
    }
}
