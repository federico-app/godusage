import Charts
import SwiftUI

/// The You tab: your own spend across your Macs, from `/v1/me/usage`. The cost card (as on the
/// Mac's panel), then your last 30 days day by day.
struct YouTabView: View {
    var model: TeamsModel
    @State private var period: BoardRange = .today

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.errorMessage { ErrorBanner(message: error) }
                    if let usage = model.myUsage {
                        CostCard(usage: usage, period: $period)
                        if usage.days.contains(where: { $0.costUSD > 0 }) {
                            dailyCard(usage)
                        }
                        footer(usage)
                    } else if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("You")
            .toolbar { AccountMenu(model: model) }
            .refreshable { await model.refresh() }
        }
    }

    private func dailyCard(_ usage: MyUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 30 Days").font(.headline).padding(.horizontal, 4)
            YourDailyChart(days: usage.days)
                .padding(14)
                .cardSurface()
        }
    }

    private func footer(_ usage: MyUsage) -> some View {
        Group {
            if let age = TeamsFormat.syncAge(usage.lastSyncAt) {
                Text(age)
            } else {
                Text("Your Macs share usage once you're in a team.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// Your spend per day, stacked by provider where the server sends the split.
private struct YourDailyChart: View {
    struct Point: Identifiable {
        var date: Date
        var provider: String
        var costUSD: Double
        var id: String { "\(date.timeIntervalSince1970)/\(provider)" }
    }

    let days: [MyUsage.Day]

    private var points: [Point] {
        days.flatMap { day -> [Point] in
            guard let date = TeamsFormat.day(day.day) else { return [] }
            guard let providers = day.providers else { return [Point(date: date, provider: "", costUSD: day.costUSD)] }
            return providers.map { Point(date: date, provider: $0.provider, costUSD: $0.costUSD) }
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.costUSD))
                .foregroundStyle(point.provider.isEmpty ? Color.accentColor : ProviderPalette.color(for: point.provider))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(TeamsFormat.dateLocale))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { Text(verbatim: value.as(Double.self).map { "$" + Int($0).formatted() } ?? "") }
            }
        }
        .frame(height: 140)
    }
}
