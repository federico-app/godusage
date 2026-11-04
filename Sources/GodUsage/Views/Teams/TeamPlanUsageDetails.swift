import SwiftUI

/// Under a plan in the Plans tab: how much of the weekly limit its accounts use per day, against the
/// pace that uses exactly the week in the team's working days, and how its 5-hour sessions went.
struct TeamPlanUsageDetails: View {
    let plan: TeamPlanReport
    let today: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let daily = plan.daily {
                        PlanDailyColumn(daily: daily, color: TotalSpendPalette.color(for: plan.provider), today: today)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let sessions = plan.sessions {
                        PlanSessionsColumn(sessions: sessions, color: TotalSpendPalette.color(for: plan.provider))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

/// The share of the weekly limit used per day over the last seven days, with the pace line.
private struct PlanDailyColumn: View {
    let daily: TeamPlanDaily
    let color: Color
    let today: String

    private static let chartHeight: CGFloat = 56

    /// Bars scale to the busiest day, and always leave room above the pace line.
    private var scale: Double {
        max(daily.pacePercent * 1.5, daily.days.compactMap(\.percent).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Per Day").font(.caption.weight(.semibold))
                Text(daily.averagePercent.map(TeamPlanUsageDetails.percent) ?? "—")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(averageStyle)
                Text("of the weekly limit per working day · full pace \(TeamPlanUsageDetails.percent(daily.pacePercent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            chart
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Under half the pace is the same warning as an underused plan.
    private var averageStyle: AnyShapeStyle {
        guard let average = daily.averagePercent, average < daily.pacePercent / 2 else { return AnyShapeStyle(.primary) }
        return Theme.notice
    }

    private var chart: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(daily.days, id: \.day) { day in
                    bar(day).frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Line()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 1)
                    .offset(y: -CGFloat(daily.pacePercent / scale) * Self.chartHeight)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }
            HStack(spacing: 6) {
                ForEach(daily.days, id: \.day) { day in
                    VStack(spacing: 0) {
                        Text(value(day)).foregroundStyle(.primary)
                        Text(label(day)).foregroundStyle(.secondary)
                    }
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(daily.days.map { "\(label($0)): \(value($0))" }.joined(separator: ", "))
    }

    private func bar(_ day: TeamPlanDaily.Day) -> some View {
        let height = day.percent.map { max(CGFloat(min($0 / scale, 1)) * Self.chartHeight, 2) } ?? 0
        return UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
            .fill(fill(day))
            .frame(height: height)
    }

    /// Days off are grey; today, still running, and estimated days are lighter.
    private func fill(_ day: TeamPlanDaily.Day) -> Color {
        if !day.working { return Color.secondary.opacity(0.35) }
        if day.day == today || day.estimated { return color.opacity(0.45) }
        return color
    }

    private func value(_ day: TeamPlanDaily.Day) -> String {
        guard let percent = day.percent else { return "—" }
        return (day.estimated ? "~" : "") + TeamPlanUsageDetails.percent(percent)
    }

    private func label(_ day: TeamPlanDaily.Day) -> String {
        if day.day == today { return "Today" }
        guard let date = TeamsFormat.date(day.day) else { return day.day }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// Where the pace leads: when an account runs out of its week, or how much of it goes unused.
    private var note: String {
        let accounts = daily.accounts == 1 ? "1 account" : "\(daily.accounts) accounts"
        guard let average = daily.averagePercent, average > 0 else { return "No finished working day read yet · \(accounts)" }
        if average >= daily.pacePercent {
            let days = String(format: "%.1f", 100 / average)
            return "Above pace: at this rate an account uses up its week in about \(days) working days · \(accounts)"
        }
        let weekShare = Int((average * 100 / daily.pacePercent).rounded())
        return "Below pace: at this rate an account uses about \(weekShare)% of its week · \(accounts)"
    }
}

/// A horizontal line across its frame, for the dashed pace line.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// The cycle's sessions: how many hit the limit, and one square per session, darker the more of it
/// was used and outlined when it hit the limit.
private struct PlanSessionsColumn: View {
    let sessions: TeamPlanSessions
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Sessions").font(.caption.weight(.semibold))
                Text("\(sessions.limitHits)")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(sessions.limitHits > 0 ? Theme.notice : AnyShapeStyle(.primary))
                Text("of \(sessions.sessions) \(sessions.sessions == 1 ? "session" : "sessions") hit the limit this cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 12, maximum: 12), spacing: 3)], alignment: .leading, spacing: 3) {
                ForEach(Array(sessions.peaks.enumerated()), id: \.offset) { _, peak in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.18 + 0.82 * min(peak, 100) / 100))
                        .overlay {
                            if peak >= 100 { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: 1.5) }
                        }
                        .frame(width: 12, height: 12)
                }
            }
            .frame(minHeight: 56, alignment: .bottomLeading)
            .accessibilityElement()
            .accessibilityLabel("\(sessions.sessions) sessions, \(sessions.limitHits) hit the limit")
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = [
            "Average peak \(TeamPlansReportView.percent(sessions.averagePeakPercent))",
            sessions.accounts == 1 ? "1 account" : "\(sessions.accounts) accounts",
        ]
        if sessions.peaks.count < sessions.sessions { parts.append("latest \(sessions.peaks.count) shown") }
        return parts.joined(separator: " · ")
    }
}
