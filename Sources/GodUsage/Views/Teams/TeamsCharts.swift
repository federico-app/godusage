import Charts
import SwiftUI

/// The Teams window's charts. Every chart colors by provider with the app's one provider palette
/// (`TotalSpendPalette`, the Total Spend ring's colors), so Claude is the same terracotta here, in
/// the popover, and on the web board. Identity never rides on color alone: each chart has a legend,
/// value labels, and a 2pt gap between segments.
struct TeamsCharts: View {
    let stats: TeamStats
    let sort: StatsSort
    let providerName: (String) -> String

    @State private var selectedDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            chartSection(
                "Who Uses What",
                subtitle: "\(metricName) per member, split by provider."
            ) { memberChart }
            if efficiencyRows.count > 0 {
                chartSection(
                    "Efficiency",
                    subtitle: "What each member pays per million tokens. Lower means cheaper models or more cache use."
                ) { efficiencyChart }
            }
            if stats.daily.count > 1 {
                chartSection(
                    "By Day",
                    subtitle: "Team \(metricName.lowercased()) per day, split by provider. Hover a day for its numbers."
                ) { dailyChart }
            }
            if !stats.models.isEmpty {
                chartSection(
                    "Top Models",
                    subtitle: "The team's most used models. Color shows each model's provider."
                ) { modelsChart }
            }
        }
    }

    private var metricName: String { sort == .cost ? "Spend" : "Tokens" }

    private func chartSection(_ title: String, subtitle: String, @ViewBuilder chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            chart()
                .padding(12)
                .cardSurface()
        }
    }

    // MARK: - Provider color scale

    /// Providers in this period, in the team's order (largest first). Only the legend order follows
    /// usage; each provider's color comes from its id.
    private var providerIDs: [String] {
        var ids = stats.providers.filter { $0.totals.value(for: sort) > 0 }.map(\.provider)
        for day in stats.daily {
            for provider in day.providers ?? [] where provider.totals.value(for: sort) > 0 && !ids.contains(provider.provider) {
                ids.append(provider.provider)
            }
        }
        for model in topModels where model.totals.value(for: sort) > 0 && !ids.contains(model.provider) { ids.append(model.provider) }
        return ids
    }

    private func applyProviderColors<C: View>(_ chart: C) -> some View {
        let ids = providerIDs
        return chart.chartForegroundStyleScale(
            domain: ids.map(providerName),
            range: ids.map(TotalSpendPalette.color(for:))
        )
    }

    // MARK: - Who Uses What

    private struct MemberSegment: Identifiable {
        var member: String
        var provider: String
        var value: Double
        var id: String { "\(member)/\(provider)" }
    }

    private var memberSegments: [MemberSegment] {
        let members = stats.members.flatMap { member in
            member.providers.compactMap { provider in
                let value = provider.totals.value(for: sort)
                return value > 0 ? MemberSegment(member: member.displayName, provider: providerName(provider.provider), value: value) : nil
            }
        }
        let shared = stats.sharedAccounts(for: TeamMetric(sort)).map { account in
            MemberSegment(member: sharedRowName(account), provider: providerName(account.provider), value: account.totals.value(for: sort))
        }
        return members + shared
    }

    /// Rows of the member chart: every member, then each shared account (counted in no member's bar).
    private var memberRows: [(name: String, totals: UsageTotals)] {
        stats.members.map { ($0.displayName, $0.totals) } + stats.sharedAccounts(for: TeamMetric(sort)).map { (sharedRowName($0), $0.totals) }
    }

    private func sharedRowName(_ account: TeamStats.SharedAccount) -> String {
        "Shared \(providerName(account.provider))"
    }

    private var memberChart: some View {
        applyProviderColors(
            Chart {
                ForEach(memberSegments) { segment in
                    BarMark(x: .value(metricName, segment.value), y: .value("Member", segment.member), height: .fixed(14))
                        .foregroundStyle(by: .value("Provider", segment.provider))
                        .cornerRadius(3)
                }
                // Each member's total, labeled once at the end of their bar. A point (unlike a bar)
                // does not stack onto the segments.
                ForEach(memberRows, id: \.name) { row in
                    PointMark(x: .value(metricName, row.totals.value(for: sort)), y: .value("Member", row.name))
                        .opacity(0)
                        .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                            Text(TeamsFormat.value(row.totals, sort: sort))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis { valueAxis }
            .chartXScale(domain: 0...(maxMemberValue * 1.18))
            .chartYScale(domain: memberRows.map(\.name))
            .chartYAxis { categoryAxis }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: max(110, CGFloat(memberRows.count) * 30 + 56))
        )
    }

    private var maxMemberValue: Double {
        max(stats.rankingTop(for: TeamMetric(sort)), sort == .cost ? 1 : 1000)
    }

    // MARK: - Efficiency

    private struct EfficiencyRow: Identifiable {
        var member: String
        var perMillion: Double
        var id: String { member }
    }

    private var efficiencyRows: [EfficiencyRow] {
        stats.members
            .compactMap { member in member.totals.costPerMillionTokens.map { EfficiencyRow(member: member.displayName, perMillion: $0) } }
            .sorted { $0.perMillion < $1.perMillion }
    }

    private var efficiencyChart: some View {
        let rows = efficiencyRows
        return Chart(rows) { row in
            BarMark(x: .value("Per 1M tokens", row.perMillion), y: .value("Member", row.member), height: .fixed(14))
                .foregroundStyle(Color.accentColor)
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    Text("\(Formatters.currency(row.perMillion)) / 1M")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(TeamsFormat.axisCurrency(number)) }
                }
            }
        }
        .chartXScale(domain: 0...((rows.map(\.perMillion).max() ?? 1) * 1.3))
        .chartYScale(domain: rows.map(\.member))
        .chartYAxis { categoryAxis }
        .frame(height: CGFloat(rows.count) * 28 + 36)
    }

    // MARK: - By Day

    private struct DaySegment: Identifiable {
        var day: Date
        var provider: String
        var value: Double
        var id: String { "\(day.timeIntervalSince1970)/\(provider)" }
    }

    private var daySegments: [DaySegment] {
        stats.daily.flatMap { day -> [DaySegment] in
            guard let date = TeamsFormat.date(day.day) else { return [] }
            return (day.providers ?? []).compactMap { provider in
                let value = provider.totals.value(for: sort)
                return value > 0 ? DaySegment(day: date, provider: providerName(provider.provider), value: value) : nil
            }
        }
    }

    private var dailyChart: some View {
        applyProviderColors(
            Chart {
                ForEach(daySegments) { segment in
                    BarMark(x: .value("Day", segment.day, unit: .day), y: .value(metricName, segment.value))
                        .foregroundStyle(by: .value("Provider", segment.provider))
                        .cornerRadius(2)
                }
                if let selectedDay, let day = dayStats(for: selectedDay) {
                    RuleMark(x: .value("Day", selectedDay, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            dayTooltip(day)
                        }
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: stats.daily.count > 10 ? 5 : 1)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { valueAxis }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: 210)
        )
    }

    private func dayStats(for date: Date) -> TeamStats.Day? {
        let key = DailyUsageAccumulator.dayKey(from: date, calendar: .current)
        return stats.daily.first { $0.day == key }
    }

    private func dayTooltip(_ day: TeamStats.Day) -> some View {
        let providers = (day.providers ?? []).filter { $0.totals.value(for: sort) > 0 }
        let total = providers.reduce(UsageTotals(tokens: 0, costUSD: 0)) {
            UsageTotals(tokens: $0.tokens + $1.tokens, costUSD: $0.costUSD + $1.costUSD)
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(TeamsFormat.dayLabel(day.day)) · \(TeamsFormat.value(total, sort: sort))")
                .font(.caption.weight(.semibold))
            ForEach(providers) { provider in
                HStack(spacing: 5) {
                    Circle().fill(TotalSpendPalette.color(for: provider.provider)).frame(width: 6, height: 6)
                    Text(providerName(provider.provider)).font(.caption2)
                    Spacer(minLength: 8)
                    Text(TeamsFormat.value(provider.totals, sort: sort)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if providers.isEmpty {
                Text("No usage").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Top Models

    private var topModels: [TeamStats.Model] { Array(stats.models.prefix(8)) }

    private var modelsChart: some View {
        applyProviderColors(
            Chart(topModels) { model in
                BarMark(x: .value(metricName, model.totals.value(for: sort)), y: .value("Model", model.model), height: .fixed(14))
                    .foregroundStyle(by: .value("Provider", providerName(model.provider)))
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                        Text(TeamsFormat.value(model.totals, sort: sort))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis { valueAxis }
            .chartXScale(domain: 0...((topModels.map { $0.totals.value(for: sort) }.max() ?? 1) * 1.22))
            .chartYScale(domain: topModels.map(\.model))
            .chartYAxis { categoryAxis }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: CGFloat(topModels.count) * 26 + 56)
        )
    }

    private var valueAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(sort == .cost ? TeamsFormat.axisCurrency(number) : TeamsFormat.tokens(Int(number)))
                }
            }
        }
    }

    /// Row names for the horizontal bar charts, in a column left of the bars.
    private var categoryAxis: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisValueLabel(horizontalSpacing: 8)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

/// A member's usage split by provider, scaled against the team's top member so bars compare across
/// rows. Shared by the dashboard's Team section and the Teams window, with a 2pt gap between segments.
struct ProviderSplitBar: View {
    let providers: [TeamStats.ProviderTotals]
    let top: Double
    let sort: StatsSort
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let segments = providers.filter { $0.totals.value(for: sort) > 0 }
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { provider in
                    Rectangle()
                        .fill(TotalSpendPalette.color(for: provider.provider))
                        .frame(width: top > 0 ? max(2, (proxy.size.width - gaps) * provider.totals.value(for: sort) / top) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}

enum TeamsFormat {
    static func value(_ totals: UsageTotals, sort: StatsSort) -> String {
        sort == .cost ? Formatters.currency(totals.costUSD) : tokens(totals.tokens)
    }

    /// Axis ticks: whole dollars once the scale reaches $10, cents below so small scales do not
    /// repeat "$0".
    static func axisCurrency(_ value: Double) -> String {
        Formatters.currency(value, fractionDigits: value == 0 || value >= 10 ? 0 : 2)
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1e9...: return String(format: "%.1fB", number / 1e9)
        case 1e6...: return String(format: "%.1fM", number / 1e6)
        case 1e3...: return String(format: "%.1fK", number / 1e3)
        default: return "\(value)"
        }
    }

    /// Day keys are calendar days with no time zone; parse them as local midnight.
    static func date(_ dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayLabel(_ dayKey: String) -> String {
        date(dayKey).map(Formatters.monthDayLabel) ?? dayKey
    }
}

/// Movement since the previous period: ▲2 (gained two places), ▼1, or "New" for a member who had no
/// usage then. Arrow and number carry the meaning; the color only reinforces it.
struct RankChangeBadge: View {
    let member: TeamStats.Member
    let range: StatsRange
    let sort: StatsSort

    var body: some View {
        if let change = member.rankChange {
            if change != 0 {
                HStack(spacing: 1) {
                    Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7))
                    Text("\(abs(change))")
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(change > 0 ? AnyShapeStyle(Theme.positive) : AnyShapeStyle(.secondary))
                .accessibilityLabel(change > 0
                    ? "Up \(change) since \(range.previousLabel)"
                    : "Down \(-change) since \(range.previousLabel)")
            }
        } else if member.totals.value(for: sort) > 0 {
            Text("New")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("No usage in \(range.previousLabel)")
        }
    }
}

extension TeamsFormat {
    /// "$3.21 / 1M" — what a member pays per million tokens.
    static func perMillion(_ totals: UsageTotals) -> String? {
        totals.costPerMillionTokens.map { "\(Formatters.currency($0)) / 1M" }
    }
}
