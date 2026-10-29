import SwiftUI

/// The Teams window's Plans tab: each subscription's cost against its covered members' usage of its
/// provider at API prices in the plan's current billing cycle, the end-of-cycle projection, the share
/// of its quota they use, and the plans on pace to leave most of it unused.
struct TeamPlansReportView: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    let providerName: (String) -> String

    private var report: TeamPlansReport? { container.teamPlans.report(teamID: teamID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let report {
                if report.plans.isEmpty {
                    emptyState(canEdit: report.canEdit)
                } else {
                    summary(report)
                    underused(report)
                    planList(report)
                    Text("Value is the usage of each provider by the members a plan covers, in the plan's current cycle, priced at API rates. Plans of one provider that cover the same usage split it by cost. Quota used is the average share of the weekly limit (Claude, Codex) or the cycle's included usage (Cursor) the plan's accounts use, per account, since one account can be shared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            } else if let error = container.teamPlans.errorMessage {
                Text(error).font(.callout).foregroundStyle(Theme.notice)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
            }
        }
        .task(id: teamID) {
            if container.teams.details[teamID] == nil { await container.teams.loadTeam(teamID) }
            await container.teamPlans.load(teamID: teamID)
        }
    }

    private func emptyState(canEdit: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No Plans Yet").font(.headline)
            Text(canEdit
                ? "Add the subscriptions this team pays for to see what each one is worth at API prices."
                : "Team owners add the team's subscriptions in Settings → Teams.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canEdit {
                Button("Add Plans…") { SettingsWindowLink.open(pane: .teams) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func summary(_ report: TeamPlansReport) -> some View {
        let totals = report.totals
        // A cycle with a price change costs each price for the days it applies.
        let cycleCost = totals.cycleCostUSD ?? totals.monthlyCostUSD
        let multiple = cycleCost > 0 ? totals.projectedValueUSD / cycleCost : 0
        return HStack(alignment: .firstTextBaseline, spacing: 28) {
            stat(Formatters.currency(totals.monthlyCostUSD), "paid per month")
            stat(Formatters.currency(totals.valueUSD), "API value so far")
            stat(Formatters.currency(totals.projectedValueUSD), "on pace this cycle")
            stat(Self.multiple(multiple), "value per dollar", emphasis: multiple >= 1 ? Theme.positive : Theme.notice)
            if let quota = totals.quota {
                stat(Self.percent(quota.usedPercent), "quota used", emphasis: Self.quotaStyle(quota.usedPercent))
                stat(Formatters.currency(quota.wastedUSD), "unused this cycle")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func stat(_ value: String, _ label: String, emphasis: AnyShapeStyle = AnyShapeStyle(.primary)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(emphasis)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func underused(_ report: TeamPlansReport) -> some View {
        let plans = report.plans.filter(\.underused)
        if !plans.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.notice)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plans.count == 1 ? "1 Plan Is Underused" : "\(plans.count) Plans Are Underused").font(.callout.weight(.semibold))
                    Text(plans.map { "\($0.name) (\(Self.underusedDetail($0)))" }.joined(separator: ", ")
                        + " — on pace to leave most of \(plans.count == 1 ? "it" : "them") unused this cycle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .cardSurface()
        }
    }

    private func planList(_ report: TeamPlansReport) -> some View {
        let scale = report.plans.map { max($0.projectedValueUSD, $0.cycleCost) }.max() ?? 1
        return VStack(spacing: 0) {
            ForEach(Array(report.plans.enumerated()), id: \.element.id) { index, plan in
                if index > 0 { Divider() }
                planRow(plan, scale: scale)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .cardSurface()
    }

    private func planRow(_ plan: TeamPlanReport, scale: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(TotalSpendPalette.color(for: plan.provider)).frame(width: 8, height: 8)
                Text(plan.name).fontWeight(.medium)
                Text(providerName(plan.provider)).font(.caption).foregroundStyle(.secondary)
                if plan.underused {
                    Text("Underused")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.notice)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(Self.multiple(plan.projectedMultiple))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(plan.underused ? Theme.notice : Theme.positive)
            }
            PlanValueBar(plan: plan, scale: scale)
            HStack {
                Text("\(Formatters.currency(plan.valueUSD)) so far · on pace for \(Formatters.currency(plan.projectedValueUSD))")
                Spacer()
                Text("\(Formatters.currency(plan.monthlyCostUSD)) / mo · \(renewalText(plan.cycle))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let quota = plan.quota {
                PlanQuotaBar(plan: plan, quota: quota)
                Text(Self.quotaText(quota, provider: plan.provider))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let covered = coverageText(plan) {
                Text(covered).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(plan.plan.visibleChanges(today: container.teams.localToday()), id: \.effectiveFrom) { change in
                Text(TeamPlanChanges.describe(change, renewalDay: plan.renewalDay, today: container.teams.localToday()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if abs(plan.cycleCost - plan.monthlyCostUSD) >= 0.01 {
                Text("This cycle costs \(Formatters.currency(plan.cycleCost)), each price for the days it applies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Who a plan with a member list covers; nothing for plans that cover everyone.
    private func coverageText(_ plan: TeamPlanReport) -> String? {
        guard let ids = plan.memberIDs else { return nil }
        let members = container.teams.details[teamID]?.members ?? []
        let names = members.filter { ids.contains($0.id) }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "Covers \(names.joined(separator: ", "))" + (plan.includesYou ? "" : " · not you")
    }

    private func renewalText(_ cycle: TeamPlanReport.Cycle) -> String {
        guard let end = TeamsFormat.date(cycle.to), let next = Calendar.current.date(byAdding: .day, value: 1, to: end) else {
            return "renews after \(cycle.to)"
        }
        let left = cycle.daysLeft + 1
        return "renews \(Formatters.monthDayLabel(next)) · \(left) \(left == 1 ? "day" : "days") left"
    }

    static func multiple(_ value: Double) -> String {
        String(format: value >= 10 ? "%.0f×" : "%.1f×", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func quotaStyle(_ usedPercent: Double) -> AnyShapeStyle {
        usedPercent < TeamPlansReportView.underusedPercent ? Theme.notice : Theme.positive
    }

    /// The server's underused line for plans with quota data (`UNDERUSED_PERCENT`).
    static let underusedPercent = 50.0

    /// Why a plan counts as underused: its quota share when there is one, else its value per dollar.
    static func underusedDetail(_ plan: TeamPlanReport) -> String {
        plan.quota.map { "\(percent($0.usedPercent)) of quota" } ?? multiple(plan.projectedMultiple)
    }

    static func quotaText(_ quota: TeamPlanQuota, provider: String) -> String {
        var parts = [
            "\(percent(quota.usedPercent)) of quota used",
            "\(Formatters.currency(quota.wastedUSD)) unused",
            quota.accounts == 1 ? "1 account" : "\(quota.accounts) accounts",
        ]
        if quota.estimatedWindows > 0 {
            // Cursor's window is its billing cycle; Claude's and Codex's a week.
            let unit = provider == "cursor" ? "cycle" : "week"
            parts.append("\(quota.estimatedWindows) \(unit)\(quota.estimatedWindows == 1 ? "" : "s") estimated")
        }
        return parts.joined(separator: " · ")
    }
}

/// The share of the plan's quota its accounts use, with a tick at the underused line.
private struct PlanQuotaBar: View {
    let plan: TeamPlanReport
    let quota: TeamPlanQuota

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let color = TotalSpendPalette.color(for: plan.provider)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.12))
                Capsule().fill(color).frame(width: max(CGFloat(min(quota.usedPercent, 100) / 100) * width, 2))
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: 8)
                    .offset(x: CGFloat(TeamPlansReportView.underusedPercent / 100) * width - 1)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("\(TeamPlansReportView.percent(quota.usedPercent)) of the plan's quota used")
    }
}

/// Value so far (solid), the projection to the end of the cycle (light), and a tick at the plan's
/// cost, all on one scale shared by the list.
private struct PlanValueBar: View {
    let plan: TeamPlanReport
    let scale: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = { (value: Double) in scale > 0 ? CGFloat(min(value / scale, 1)) * width : 0 }
            let color = TotalSpendPalette.color(for: plan.provider)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.12))
                Capsule().fill(color.opacity(0.3)).frame(width: max(x(plan.projectedValueUSD), 2))
                Capsule().fill(color).frame(width: max(x(plan.valueUSD), 2))
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: 12)
                    .offset(x: x(plan.cycleCost) - 1)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("\(Formatters.currency(plan.valueUSD)) of API value so far, on pace for \(Formatters.currency(plan.projectedValueUSD)), against \(Formatters.currency(plan.cycleCost)) this cycle")
    }
}
