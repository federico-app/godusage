import Charts
import SwiftUI

/// The Teams window's By Model chart: the team's usage per day, week, or month, each bar split by
/// model. Models take their provider's color in a different shade each (`TeamModelPalette`); the
/// models outside the period's eight largest are summed as Other.
struct TeamModelsOverTimeChart: View {
    enum Bucket: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }

        var unit: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    let stats: TeamStats
    let sort: StatsSort
    @Binding var bucket: Bucket

    @State private var selected: Date?

    static let otherName = "Other"

    struct Segment: Identifiable {
        var start: Date
        var model: String
        var value: Double
        var id: String { "\(start.timeIntervalSince1970)/\(model)" }
    }

    /// One bar per bucket with its models, largest first (the order the stack is drawn in).
    struct Bar: Identifiable {
        var start: Date
        var models: [(name: String, totals: UsageTotals)]
        var id: Date { start }
    }

    /// The default bucket for a range: a year reads best by month, shorter periods by day.
    static func defaultBucket(for range: StatsRange) -> Bucket {
        range == .year ? .month : .day
    }

    /// Sums the days into buckets. Pure, so it is unit-tested.
    static func bars(daily: [TeamStats.Day], bucket: Bucket, calendar: Calendar = .current) -> [Bar] {
        var order: [Date] = []
        var sums: [Date: [String: UsageTotals]] = [:]
        for day in daily {
            guard let date = TeamsFormat.date(day.day),
                  let start = calendar.dateInterval(of: bucket.unit, for: date)?.start
            else { continue }
            if sums[start] == nil {
                order.append(start)
                sums[start] = [:]
            }
            for model in day.models ?? [] {
                sums[start]![model.model, default: UsageTotals(tokens: 0, costUSD: 0)].add(model.totals)
            }
            if let other = day.otherModels {
                sums[start]![otherName, default: UsageTotals(tokens: 0, costUSD: 0)].add(other)
            }
        }
        return order.map { start in
            Bar(start: start, models: sums[start]!.map { (name: $0.key, totals: $0.value) })
        }
    }

    /// The period's models in usage order, the order of the legend and of each stack.
    private var modelOrder: [(provider: String, model: String)] {
        var seen = Set<String>()
        var models: [(provider: String, model: String)] = []
        for model in stats.models where model.totals.value(for: sort) > 0 {
            if seen.insert(model.model).inserted { models.append((model.provider, model.model)) }
        }
        // A model only in the per-day lists (it can't be, but the scale must cover every series).
        for day in stats.daily {
            for model in day.models ?? [] where seen.insert(model.model).inserted {
                models.append((model.provider, model.model))
            }
        }
        return models
    }

    private var bars: [Bar] {
        let rank = Dictionary(uniqueKeysWithValues: modelOrder.enumerated().map { ($1.model, $0) })
        return Self.bars(daily: stats.daily, bucket: bucket).map { bar in
            var bar = bar
            bar.models = bar.models
                .filter { $0.totals.value(for: sort) > 0 }
                .sorted { (rank[$0.name] ?? .max) < (rank[$1.name] ?? .max) }
            return bar
        }
    }

    var body: some View {
        let bars = bars
        let order = modelOrder
        let colors = TeamModelPalette.colors(for: order)
        let names = order.map(\.model).filter { name in bars.contains { $0.models.contains { $0.name == name } } }
        let hasOther = bars.contains { $0.models.contains { $0.name == Self.otherName } }
        let domain = names + (hasOther ? [Self.otherName] : [])
        let range = names.map { name in
            order.first { $0.model == name }.flatMap { colors["\($0.provider)/\($0.model)"] } ?? .gray
        } + (hasOther ? [Color.gray.opacity(0.45)] : [])

        VStack(alignment: .trailing, spacing: 8) {
            Picker("Group By", selection: $bucket) {
                ForEach(Bucket.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Chart {
                ForEach(bars) { bar in
                    ForEach(bar.models, id: \.name) { model in
                        BarMark(x: .value("Period", bar.start, unit: bucket.unit), y: .value(sort == .cost ? "Spend" : "Tokens", model.totals.value(for: sort)))
                            .foregroundStyle(by: .value("Model", model.name))
                            .cornerRadius(2)
                    }
                }
                if let selected, let bar = bar(at: selected, in: bars) {
                    RuleMark(x: .value("Period", bar.start, unit: bucket.unit))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(bar, colors: Dictionary(uniqueKeysWithValues: zip(domain, range)))
                        }
                }
            }
            .chartForegroundStyleScale(domain: domain, range: range)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    if bucket == .month {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                    } else {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(sort == .cost ? TeamsFormat.axisCurrency(number) : TeamsFormat.tokens(Int(number)))
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: 240)
        }
    }

    private func bar(at date: Date, in bars: [Bar]) -> Bar? {
        guard let start = Calendar.current.dateInterval(of: bucket.unit, for: date)?.start else { return nil }
        return bars.first { $0.start == start }
    }

    private func label(_ start: Date) -> String {
        switch bucket {
        case .day: start.formatted(.dateTime.day().month(.abbreviated))
        case .week: "Week of \(start.formatted(.dateTime.day().month(.abbreviated)))"
        case .month: start.formatted(.dateTime.month(.wide).year())
        }
    }

    private func tooltip(_ bar: Bar, colors: [String: Color]) -> some View {
        let total = bar.models.reduce(UsageTotals(tokens: 0, costUSD: 0)) { partial, model in
            var sum = partial
            sum.add(model.totals)
            return sum
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(label(bar.start)) · \(TeamsFormat.value(total, sort: sort))")
                .font(.caption.weight(.semibold))
            ForEach(bar.models, id: \.name) { model in
                HStack(spacing: 5) {
                    Circle().fill(colors[model.name] ?? .gray).frame(width: 6, height: 6)
                    Text(model.name).font(.caption2)
                    Spacer(minLength: 8)
                    Text(TeamsFormat.value(model.totals, sort: sort)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if bar.models.isEmpty {
                Text("No usage").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension UsageTotals {
    mutating func add(_ other: UsageTotals) {
        tokens += other.tokens
        costUSD += other.costUSD
    }
}
