import SwiftUI

/// The pieces This Week's Limit draws for each plan, as on the Mac (`TeamWeekBoxes.swift`): the
/// plan's title, today's bar, and the week's boxes.

/// The provider's dot, the plan's name (wrapping, never cut), a claimed reset's line, and the figure
/// on the right.
struct PlanTitle<Trailing: View>: View {
    let plan: TeamPlans.Plan
    let budget: TeamPlans.Budget
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(ProviderPalette.color(for: plan.provider)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: plan.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let week = budget.week {
                    Text(Self.weekLine(week))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
    }

    /// "↻ 95% + 40% of 200% this week": a week with a claimed reset holds another limit per claim.
    static func weekLine(_ week: TeamPlans.WeekCapacity) -> String {
        let mark = "↻"
        let used = if let segments = week.segments, segments.count > 1 {
            segments.map(TeamsFormat.percent).joined(separator: " + ")
        } else {
            TeamsFormat.percent(week.usedPercent)
        }
        let capacity = TeamsFormat.percent(week.capacityPercent)
        return String(
            localized: "\(mark) \(used) of \(capacity) this week",
            comment: "A week with a claimed limit reset: the use (each stretch between resets, added up), then the week's capacity, e.g. ↻ 95% + 40% of 200% this week"
        )
    }
}

/// Today's bar: the track is today's budget, the fill today's use, and a dark tick where today's use
/// should be now. Over the budget, the budget is the tick and the part past it is striped.
struct TodayBar: View {
    let geometry: TodayBarGeometry
    let color: Color

    private static let height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: width * geometry.fill)
                    if geometry.overflow > 0 {
                        Stripes().fill(WeekLimitColors.over)
                            .background(Color.orange.opacity(0.75))
                            .frame(width: width * geometry.overflow)
                            .clipped()
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())
                if let tick = geometry.budgetTick ?? geometry.nowTick {
                    Capsule().fill(.primary)
                        .frame(width: 2, height: Self.height + 6)
                        .offset(x: min(max(width * tick - 1, 0), width - 2))
                }
            }
            .frame(height: Self.height + 6)
        }
        .frame(height: Self.height + 6)
        .accessibilityHidden(true)
    }
}

/// The week as a row of small boxes: days gone by filled to their use, today filled against its
/// budget (spilling over the top past it), the working days left as dashed outlines at their budget,
/// and "off" for days without working hours.
struct WeekBoxesView: View {
    let boxes: [WeekBox]
    let color: Color

    private static let box: CGFloat = 26
    private var maxHeight: CGFloat { Self.box * WeekBox.maxHeight }
    private var hasLabels: Bool {
        boxes.contains { if case .future(_, _, let label) = $0.kind { label != nil } else { false } }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(boxes, id: \.day) { day in
                VStack(spacing: 2) {
                    if hasLabels { label(day).frame(height: 11) }
                    content(day.kind).frame(maxWidth: .infinity).frame(height: maxHeight, alignment: .bottom)
                    Text(verbatim: day.reset ? "\(day.label)↻" : day.label)
                        .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func label(_ day: WeekBox) -> some View {
        if case .future(_, _, let text?) = day.kind {
            Text(verbatim: text).font(.system(size: 8, weight: .semibold).monospacedDigit()).foregroundStyle(WeekLimitColors.noticeText)
                .lineLimit(1).minimumScaleFactor(0.7)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ kind: WeekBox.Kind) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        switch kind {
        case let .past(fill, estimated):
            shape.fill(color.opacity(estimated ? 0.4 : 0.85)).frame(height: max(Self.box * fill, 2))
        case let .today(fill, overflow):
            VStack(spacing: 0) {
                if overflow > 0 {
                    Stripes().fill(WeekLimitColors.over)
                        .background(Color.orange.opacity(0.75))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .frame(height: max(Self.box * overflow, 3))
                }
                ZStack(alignment: .bottom) {
                    Rectangle().fill(color).frame(height: Self.box * fill)
                }
                .frame(height: Self.box, alignment: .bottom)
                .clipShape(overflow > 0 ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)) : AnyShape(shape))
                .overlay { if overflow == 0 { shape.strokeBorder(color, lineWidth: 1.5) } }
            }
        case let .future(height, lowered, _):
            shape.strokeBorder(lowered ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                .frame(height: Self.box * min(height, WeekBox.maxHeight))
        case .off:
            Text("off", comment: "A day without working hours in the week's boxes.").font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: Self.box)
        case .empty:
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }
}

/// Diagonal stripes for use past a budget.
struct Stripes: Shape {
    var stripe: CGFloat = 3
    var gap: CGFloat = 2.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height + stripe, y: rect.minY))
            path.addLine(to: CGPoint(x: x + stripe, y: rect.maxY))
            path.closeSubpath()
            x += stripe + gap
        }
        return path
    }
}
