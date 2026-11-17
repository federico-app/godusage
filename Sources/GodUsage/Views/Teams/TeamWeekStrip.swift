import SwiftUI

/// In the dashboard's Team section, above the ranking: for each plan with an open weekly limit, its
/// week so far as a row of small boxes, one per day, with today's use against what today can afford
/// (what's left of the week spread over the working days until the reset) and the working days left
/// drawn at that budget. Plans are grouped under their team's name: in the card's title when they all
/// come from one team other than the selected one, else above each team's plans (see `YourTeamPlans`).
/// With Live Pace on (Customize → Team), plans the server sends a pace for show it instead (see
/// `TeamLivePaceStrip`).
struct TeamWeekStripCard: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(TeamDashboardPreferences.showLivePaceKey) private var showLivePace = true

    let plans: [TeamPlanEntry]
    let selectedTeamID: String?
    let teamName: (String) -> String?
    let today: String

    private var budgeted: [(TeamPlanEntry, TeamPlanBudget)] {
        plans.compactMap { entry in entry.plan.budget.map { (entry, $0) } }
    }

    var body: some View {
        let rows = budgeted
        if !rows.isEmpty {
            // Live Pace moves with the clock, so the card redraws every minute.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let paces = showLivePace ? livePaces(rows.map(\.0), now: context.date) : [:]
                let roomFor = Self.useThisNow(rows.map(\.0), paces: paces)
                let groups = Self.groups(rows) { $0.0.teamID }
                let headers = Self.headers(groups.map(\.teamID), selectedTeamID: selectedTeamID)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("This Week's Limit")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        if case let .title(teamID) = headers, let name = teamName(teamID) {
                            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.teamID) { index, group in
                        if index > 0 { Divider() }
                        if headers == .perGroup, let name = teamName(group.teamID) {
                            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ForEach(Array(group.rows.enumerated()), id: \.element.0.id) { rowIndex, row in
                            if rowIndex > 0 { Divider() }
                            strip(row.0, budget: row.1, paces: paces, roomFor: roomFor, count: rows.count)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .cardSurface()
        }
    }

    @ViewBuilder
    private func strip(_ entry: TeamPlanEntry, budget: TeamPlanBudget, paces: [String: LivePace], roomFor: Set<String>, count: Int) -> some View {
        if let live = paces[entry.id], let pace = budget.pace {
            TeamLivePaceStrip(
                teamID: entry.teamID, plan: entry.plan, budget: budget, pace: pace, live: live, useThisNow: roomFor.contains(entry.id), today: today
            )
        } else {
            // Three plans or more drop the line under each strip to stay short.
            TeamWeekStrip(teamID: entry.teamID, plan: entry.plan, budget: budget, today: today, showsNote: count < 3)
        }
    }

    private func livePaces(_ entries: [TeamPlanEntry], now: Date) -> [String: LivePace] {
        var paces: [String: LivePace] = [:]
        for entry in entries {
            if let live = container.teamPlans.livePace(entry, now: now) { paces[entry.id] = live }
        }
        return paces
    }

    /// The rows by team, each team once, in the order its first plan comes.
    static func groups<Row>(_ rows: [Row], teamID: (Row) -> String) -> [(teamID: String, rows: [Row])] {
        var groups: [(teamID: String, rows: [Row])] = []
        for row in rows {
            let id = teamID(row)
            if let index = groups.firstIndex(where: { $0.teamID == id }) {
                groups[index].rows.append(row)
            } else {
                groups.append((id, [row]))
            }
        }
        return groups
    }

    enum Headers: Equatable {
        /// Only the selected team's plans: the dashboard already says which team.
        case none
        /// One other team: its name sits in the card's title.
        case title(String)
        /// Several teams: each one's name above its plans.
        case perGroup
    }

    static func headers(_ teamIDs: [String], selectedTeamID: String?) -> Headers {
        guard teamIDs.count == 1, let only = teamIDs.first else { return teamIDs.isEmpty ? .none : .perGroup }
        return only == selectedTeamID ? .none : .title(only)
    }

    /// Plans with room while another provider's plan runs hot (over today's budget or well ahead of
    /// pace): their pill is tinted green. Room means on pace or behind, with at least
    /// `roomForOthers` points of today's budget left.
    static func useThisNow(_ entries: [TeamPlanEntry], paces: [String: LivePace]) -> Set<String> {
        let hot = Set(entries.filter { [.ahead, .overBudget].contains(paces[$0.id]?.state) }.map(\.plan.provider))
        guard !hot.isEmpty else { return [] }
        return Set(entries.filter { entry in
            guard let live = paces[entry.id], !hot.contains(entry.plan.provider) else { return false }
            return [.onPace, .behind].contains(live.state) && live.budget - live.used >= roomForOthers
        }.map(\.id))
    }

    static let roomForOthers = 5.0
}

/// One plan in This Week's Limit without Live Pace: today's use against today's budget, the week's
/// boxes, and a line with what's left today and when the limit resets.
struct TeamWeekStrip: View {
    let teamID: String
    let plan: TeamPlanReport
    let budget: TeamPlanBudget
    let today: String
    let showsNote: Bool

    private var color: Color { TotalSpendPalette.color(for: plan.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeamPlanTitle(teamID: teamID, plan: plan, budget: budget) { figure }
            TeamWeekBoxes(boxes: Self.boxes(budget, today: today), color: color)
            if showsNote {
                Text(Self.note(budget))
                    .font(.caption2)
                    .foregroundStyle(overBudget ? AnyShapeStyle(WeekLimitColors.noticeText) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overBudget: Bool { Self.isOverBudget(budget) }

    private var figure: some View {
        (Text(Self.percent(budget.todayPercent))
            .fontWeight(.semibold)
            .foregroundStyle(overBudget ? AnyShapeStyle(WeekLimitColors.noticeText) : AnyShapeStyle(.primary))
            + Text(" of \(Self.percent(budget.affordablePercent)) today").foregroundStyle(.secondary))
            .font(.caption.monospacedDigit())
            .fixedSize()
    }

    /// The week's boxes: the working days left all at today's budget.
    static func boxes(_ budget: TeamPlanBudget, today: String) -> [WeekBox] {
        let future = budget.days.filter { $0.day > today && $0.working }
            .map { (day: $0.day, budget: budget.affordablePercent, planned: budget.affordablePercent) }
        return WeekBox.boxes(
            days: budget.days, today: today, used: budget.todayPercent, budget: budget.affordablePercent, future: future, labelsLowered: false
        )
    }

    static func isOverBudget(_ budget: TeamPlanBudget) -> Bool { budget.todayPercent > budget.affordablePercent }

    static func note(_ budget: TeamPlanBudget) -> String {
        let reset = GodUsageISO8601.date(from: budget.resetsAt).map(LivePaceFormat.weekdayTime) ?? budget.resetsAt
        if isOverBudget(budget) {
            return "\(Self.percent(budget.todayPercent - budget.affordablePercent)) over today's budget · resets \(reset)"
        }
        return "\(Self.percent(budget.affordablePercent - budget.todayPercent)) more today on budget · resets \(reset)"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
