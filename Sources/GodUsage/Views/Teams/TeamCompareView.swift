import Charts
import SwiftUI

/// Two members side by side: totals, rank, efficiency, each provider as mirrored bars (provider
/// colors), their top models, and their days as two lines. The two people are told apart by line
/// style and name, never by a provider color.
struct TeamCompareView: View {
    let stats: TeamStats
    let sort: StatsSort
    let currentUserID: String?
    let providerName: (String) -> String

    @State private var leftID: String?
    @State private var rightID: String?

    var body: some View {
        let left = member(leftID) ?? defaultLeft
        let right = member(rightID) ?? defaultRight(excluding: left)
        VStack(alignment: .leading, spacing: 20) {
            if let left, let right, left.userID != right.userID {
                header(left, right)
                providers(left, right)
                models(left, right)
                if stats.daily.count > 1 { days(left, right) }
            } else {
                Text("Comparing needs at least two members in the team.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            }
        }
    }

    private func member(_ id: String?) -> TeamStats.Member? {
        id.flatMap { id in stats.members.first { $0.userID == id } }
    }

    private var defaultLeft: TeamStats.Member? {
        stats.members.first { $0.userID == currentUserID } ?? stats.members.first
    }

    private func defaultRight(excluding left: TeamStats.Member?) -> TeamStats.Member? {
        stats.members.first { $0.userID != left?.userID }
    }

    // MARK: - Header

    private func header(_ left: TeamStats.Member, _ right: TeamStats.Member) -> some View {
        HStack(alignment: .top, spacing: 12) {
            personCard(left, selection: $leftID, excluding: right.userID)
            Text("vs").font(.headline).foregroundStyle(.secondary).padding(.top, 24)
            personCard(right, selection: $rightID, excluding: left.userID)
        }
    }

    private func personCard(_ member: TeamStats.Member, selection: Binding<String?>, excluding: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Member", selection: Binding(get: { member.userID }, set: { selection.wrappedValue = $0 })) {
                ForEach(stats.members.filter { $0.userID != excluding }) { Text($0.displayName).tag($0.userID) }
            }
            .labelsHidden()
            .fixedSize()
            Text(TeamsFormat.value(member.totals, sort: sort))
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
            HStack(spacing: 6) {
                Text("#\(member.rank)").font(.callout.weight(.semibold))
                RankChangeBadge(member: member, range: stats.range.name, sort: sort)
            }
            Text(TeamsFormat.perMillion(member.totals) ?? "No tokens yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
    }

    // MARK: - Providers

    private func providers(_ left: TeamStats.Member, _ right: TeamStats.Member) -> some View {
        let ids = (left.providers + right.providers).map(\.provider).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let value = { (member: TeamStats.Member, id: String) in member.providers.first { $0.provider == id }?.totals ?? UsageTotals(tokens: 0, costUSD: 0) }
        let top = ids.flatMap { [value(left, $0).value(for: sort), value(right, $0).value(for: sort)] }.max() ?? 0
        return section("By Provider", subtitle: "Each provider for both, left and right of the center line.") {
            VStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    let a = value(left, id), b = value(right, id)
                    HStack(spacing: 8) {
                        Text(TeamsFormat.value(a, sort: sort)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                        mirroredBar(fraction: top > 0 ? a.value(for: sort) / top : 0, color: TotalSpendPalette.color(for: id), leading: true)
                        Text(providerName(id)).font(.caption.weight(.medium)).frame(width: 84)
                        mirroredBar(fraction: top > 0 ? b.value(for: sort) / top : 0, color: TotalSpendPalette.color(for: id), leading: false)
                        Text(TeamsFormat.value(b, sort: sort)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .leading)
                    }
                }
                if ids.isEmpty {
                    Text("Neither has usage in this period.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mirroredBar(fraction: Double, color: Color, leading: Bool) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if leading { Spacer(minLength: 0) }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * fraction))
                if !leading { Spacer(minLength: 0) }
            }
        }
        .frame(height: 10)
    }

    // MARK: - Models

    private func models(_ left: TeamStats.Member, _ right: TeamStats.Member) -> some View {
        section("Top Models", subtitle: "Each person's most used models. The dot shows the provider.") {
            HStack(alignment: .top, spacing: 16) {
                modelList(for: left)
                Divider()
                modelList(for: right)
            }
        }
    }

    private func modelList(for member: TeamStats.Member) -> some View {
        let rows = stats.models
            .compactMap { model -> (TeamStats.Model, UsageTotals)? in
                model.members.first { $0.userID == member.userID }.map { (model, $0.totals) }
            }
            .filter { $0.1.value(for: sort) > 0 }
            .sorted { $0.1.value(for: sort) > $1.1.value(for: sort) }
            .prefix(5)
        return VStack(alignment: .leading, spacing: 5) {
            Text(member.displayName).font(.caption.weight(.semibold))
            ForEach(Array(rows), id: \.0.id) { model, totals in
                HStack(spacing: 6) {
                    Circle().fill(TotalSpendPalette.color(for: model.provider)).frame(width: 6, height: 6)
                    Text(model.model).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(TeamsFormat.value(totals, sort: sort)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty { Text("No models").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Days

    private struct DayPoint: Identifiable {
        var day: Date
        var person: String
        var value: Double
        var id: String { "\(person)/\(day.timeIntervalSince1970)" }
    }

    private func days(_ left: TeamStats.Member, _ right: TeamStats.Member) -> some View {
        let points = stats.daily.flatMap { day -> [DayPoint] in
            guard let date = TeamsFormat.date(day.day) else { return [] }
            return [left, right].map { person in
                let totals = day.members.first { $0.userID == person.userID }?.totals ?? UsageTotals(tokens: 0, costUSD: 0)
                return DayPoint(day: date, person: person.displayName, value: totals.value(for: sort))
            }
        }
        return section("By Day", subtitle: "\(left.displayName) is the solid line, \(right.displayName) the dashed one.") {
            Chart(points) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Person", point.person))
                    .lineStyle(by: .value("Person", point.person))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: [left.displayName, right.displayName], range: [Color.primary, Color.secondary])
            .chartLineStyleScale(domain: [left.displayName, right.displayName], range: [StrokeStyle(lineWidth: 2), StrokeStyle(lineWidth: 2, dash: [5, 4])])
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(sort == .cost ? Formatters.currency(number, fractionDigits: 0) : TeamsFormat.tokens(Int(number)))
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 180)
        }
    }

    private func section(_ title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }
}
