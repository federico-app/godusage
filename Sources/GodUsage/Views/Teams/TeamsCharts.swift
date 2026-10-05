import Charts
import SwiftUI

/// "Who uses what": spend or tokens per member split by provider, the daily trend per member, and
/// the team's top models.
struct TeamsCharts: View {
    let stats: TeamStats
    let sort: StatsSort
    let providerName: (String) -> String

    private struct ProviderBar: Identifiable {
        var member: String
        var provider: String
        var value: Double
        var id: String { "\(member)/\(provider)" }
    }

    private struct DayBar: Identifiable {
        var day: Date
        var member: String
        var value: Double
        var id: String { "\(day.timeIntervalSince1970)/\(member)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            chartSection("By Provider") { providerChart }
            if stats.daily.count > 1 {
                chartSection("By Day") { dailyChart }
            }
            if !stats.models.isEmpty {
                chartSection("Top Models") { modelsChart }
            }
        }
    }

    private func chartSection(_ title: String, @ViewBuilder chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            chart()
                .padding(12)
                .cardSurface()
        }
    }

    private var providerBars: [ProviderBar] {
        stats.members.flatMap { member in
            member.providers.map { provider in
                ProviderBar(member: member.displayName, provider: providerName(provider.provider), value: provider.totals.value(for: sort))
            }
        }
        .filter { $0.value > 0 }
    }

    private var providerChart: some View {
        Chart(providerBars) { bar in
            BarMark(x: .value(sort.label, bar.value), y: .value("Member", bar.member))
                .foregroundStyle(by: .value("Provider", bar.provider))
        }
        .chartXAxis { valueAxis }
        .chartYScale(domain: stats.members.map(\.displayName))
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: max(120, CGFloat(stats.members.count) * 32 + 50))
    }

    private var dayBars: [DayBar] {
        let names = Dictionary(uniqueKeysWithValues: stats.members.map { ($0.userID, $0.displayName) })
        return stats.daily.flatMap { day -> [DayBar] in
            guard let date = TeamsFormat.date(day.day) else { return [] }
            return day.members.compactMap { member in
                let value = member.totals.value(for: sort)
                guard value > 0 else { return nil }
                return DayBar(day: date, member: names[member.userID] ?? "Former Member", value: value)
            }
        }
    }

    private var dailyChart: some View {
        Chart(dayBars) { bar in
            BarMark(x: .value("Day", bar.day, unit: .day), y: .value(sort.label, bar.value))
                .foregroundStyle(by: .value("Member", bar.member))
        }
        .chartYAxis { valueAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }

    private var topModels: [TeamStats.Model] {
        Array(stats.models.prefix(10))
    }

    private var modelsChart: some View {
        Chart(topModels) { model in
            BarMark(x: .value(sort.label, model.totals.value(for: sort)), y: .value("Model", model.model))
                .foregroundStyle(by: .value("Provider", providerName(model.provider)))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(TeamsFormat.value(model.totals, sort: sort))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis { valueAxis }
        .chartYScale(domain: topModels.map(\.model))
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: CGFloat(topModels.count) * 26 + 50)
    }

    private var valueAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(sort == .cost ? Formatters.currency(number, fractionDigits: 0) : TeamsFormat.tokens(Int(number)))
                }
            }
        }
    }
}

enum TeamsFormat {
    static func value(_ totals: UsageTotals, sort: StatsSort) -> String {
        sort == .cost ? Formatters.currency(totals.costUSD) : tokens(totals.tokens)
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
