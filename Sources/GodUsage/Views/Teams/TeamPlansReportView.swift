import SwiftUI

/// The Teams window's Plans tab: each subscription's cost against the team's usage of its provider
/// at API prices in the plan's current billing cycle, the end-of-cycle projection, and the plans
/// projected to be worth less than they cost.
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
                    Text("Value is the team's usage of each provider in the plan's current cycle, priced at API rates. Several plans of one provider split its usage by cost.")
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
        .task(id: teamID) { await container.teamPlans.load(teamID: teamID) }
    }

    private func emptyState(canEdit: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No Plans Yet").font(.headline)
            Text(canEdit
                ? "Add the subscriptions this team pays for to see what each one is worth at API prices."
                : "The team owner adds the team's subscriptions in Settings → Teams.")
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
        let multiple = totals.monthlyCostUSD > 0 ? totals.projectedValueUSD / totals.monthlyCostUSD : 0
        return HStack(alignment: .firstTextBaseline, spacing: 28) {
            stat(Formatters.currency(totals.monthlyCostUSD), "paid per month")
            stat(Formatters.currency(totals.valueUSD), "API value so far")
            stat(Formatters.currency(totals.projectedValueUSD), "on pace this cycle")
            stat(Self.multiple(multiple), "value per dollar", emphasis: multiple >= 1 ? Theme.positive : Theme.notice)
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
                    Text(plans.map { "\($0.name) (\(Self.multiple($0.projectedMultiple)))" }.joined(separator: ", ")
                        + " — on pace to be worth less than \(plans.count == 1 ? "it costs" : "they cost") this cycle.")
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
        let scale = report.plans.map { max($0.projectedValueUSD, $0.monthlyCostUSD) }.max() ?? 1
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
        }
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
                    .offset(x: x(plan.monthlyCostUSD) - 1)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("\(Formatters.currency(plan.valueUSD)) of API value so far, on pace for \(Formatters.currency(plan.projectedValueUSD)), against \(Formatters.currency(plan.monthlyCostUSD)) a month")
    }
}
