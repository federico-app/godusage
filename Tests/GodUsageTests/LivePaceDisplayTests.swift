import XCTest
@testable import GodUsage

/// What This Week's Limit shows: the pill, today's bar, the note under it, the week's boxes, and the
/// over-budget summary. Same day as `LivePaceTests`: Thursday 2026-11-05, working 07:00–11:00 and
/// 12:00–16:00 UTC, a budget of 20% and 60% left; Friday and Monday follow with 8 hours each.
final class LivePaceDisplayTests: XCTestCase {
    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func live(used: Double, rate: Double?, at time: String, futureDays: [TeamPlanPace.FutureDay]? = nil) -> LivePace {
        let pace = TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: futureDays ?? [.init(day: "2026-11-06", hours: 8), .init(day: "2026-11-09", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
        return LivePace(pace: pace, now: at(time))
    }

    // MARK: - Pill

    func testThePillSaysAheadOrUnderInWords() {
        let ahead = live(used: 12, rate: 4, at: "11:30")
        XCTAssertEqual(LivePaceDisplay.pill(ahead, useThisNow: false).text, "48 min ahead of pace")
        XCTAssertEqual(LivePaceDisplay.pill(ahead, useThisNow: false).style, .hot)

        // 12:30: 11.25% expected, 7% used: 1h 42m under, heading well under the budget.
        let behind = live(used: 7, rate: 1, at: "12:30")
        XCTAssertEqual(LivePaceDisplay.pill(behind, useThisNow: false).text, "1h 42m under pace")
        XCTAssertEqual(LivePaceDisplay.pill(behind, useThisNow: false).style, .cool)
        // The plan to use while another runs hot: same words, green; the banner says why.
        XCTAssertEqual(LivePaceDisplay.pill(behind, useThisNow: true).text, "1h 42m under pace")
        XCTAssertEqual(LivePaceDisplay.pill(behind, useThisNow: true).style, .cool)

        // 09:00: 5% expected, 5% used.
        let onPace = live(used: 5, rate: 2.5, at: "09:00")
        XCTAssertEqual(LivePaceDisplay.pill(onPace, useThisNow: false).text, "On pace")
        XCTAssertEqual(LivePaceDisplay.pill(onPace, useThisNow: false).style, .neutral)
        XCTAssertEqual(LivePaceDisplay.pill(onPace, useThisNow: true).text, "On pace")
        XCTAssertEqual(LivePaceDisplay.pill(onPace, useThisNow: true).style, .cool)
    }

    func testOnlyPlansAheadOrAtOrOverBudgetStayExpanded() {
        let expanded: [LivePace.State] = [.ahead, .overBudget, .atBudget]
        let collapsed: [LivePace.State] = [.onPace, .behind, .warmingUp, .notStarted, .dayDone, .dayOff]
        XCTAssertTrue(expanded.allSatisfy { !LivePaceDisplay.collapses($0) })
        XCTAssertTrue(collapsed.allSatisfy { LivePaceDisplay.collapses($0) })
        XCTAssertFalse(LivePaceDisplay.collapses(live(used: 12, rate: 4, at: "11:30").state))
        XCTAssertTrue(LivePaceDisplay.collapses(live(used: 7, rate: 1, at: "12:30").state))
    }

    func testOverTheBudgetThePillIsSolidAndSaysHowFarOver() {
        let over = live(used: 26.3, rate: 2.5, at: "14:00")
        XCTAssertEqual(LivePaceDisplay.pill(over, useThisNow: false).text, "6.3% over today")
        XCTAssertEqual(LivePaceDisplay.pill(over, useThisNow: false).style, .over)
    }

    func testOutsideTheWorkingDayThePillIsGrey() {
        XCTAssertEqual(LivePaceDisplay.pill(live(used: 0, rate: nil, at: "06:00"), useThisNow: false).style, .muted)
        XCTAssertTrue(LivePaceDisplay.pill(live(used: 0, rate: nil, at: "06:00"), useThisNow: false).text.hasPrefix("Starts "))
        XCTAssertEqual(LivePaceDisplay.pill(live(used: 16, rate: 0, at: "17:00"), useThisNow: false).text, "Day Done")
    }

    // MARK: - Today's bar

    func testTheBarFillsTodaysBudgetWithANowTickAtTheEvenPace() throws {
        // 11:30: 12% of 20% used, 10% expected.
        let bar = TodayBarGeometry(live(used: 12, rate: 4, at: "11:30"))
        XCTAssertEqual(bar.fill, 0.6, accuracy: 0.0001)
        XCTAssertEqual(bar.overflow, 0)
        XCTAssertNil(bar.budgetTick)
        XCTAssertEqual(try XCTUnwrap(bar.nowTick), 0.5, accuracy: 0.0001)
    }

    func testOverTheBudgetTheBarStretchesAndTheBudgetBecomesATick() throws {
        let bar = TodayBarGeometry(live(used: 25, rate: 2.5, at: "14:00"))
        XCTAssertEqual(bar.fill, 0.8, accuracy: 0.0001)
        XCTAssertEqual(bar.overflow, 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bar.budgetTick), 0.8, accuracy: 0.0001)
        XCTAssertNil(bar.nowTick, "over the budget only the budget is ticked")
    }

    func testOutsideTheWorkingDayTheBarHasNoNowTick() {
        XCTAssertNil(TodayBarGeometry(live(used: 0, rate: nil, at: "06:00")).nowTick)
        XCTAssertNil(TodayBarGeometry(live(used: 16, rate: 0, at: "17:00")).nowTick)
        let empty = TodayBarGeometry(used: 0, budget: 0, expected: 0)
        XCTAssertEqual(empty.fill, 0)
        XCTAssertNil(empty.nowTick)
    }

    // MARK: - Note

    func testTheNoteSaysWhenTheBudgetRunsOutOrWhereTheOverflowGoes() {
        let ahead = LivePaceDisplay.note(live(used: 12, rate: 4, at: "11:30"))
        XCTAssertEqual(ahead?.text, "At this pace today’s budget runs out at \(LivePaceFormat.time(at("14:00"))).")
        XCTAssertEqual(ahead?.style, .notice)

        let over = LivePaceDisplay.note(live(used: 26.3, rate: 2.5, at: "14:00"))
        XCTAssertEqual(over?.text, "Today’s budget is used up. The 6.3% comes out of the next working days.")

        let lastDay = LivePaceDisplay.note(live(used: 26.3, rate: 2.5, at: "14:00", futureDays: []))
        XCTAssertEqual(lastDay?.text, "Over today’s budget, on the last working day before the reset.")

        XCTAssertNil(LivePaceDisplay.note(live(used: 7, rate: 1, at: "12:30")))
    }

    // MARK: - Summary

    func testOverTheBudgetTheDetailsLineSummarizesTheDaysLeft() throws {
        // 14:00, 26% used at 2.5%/h: today ends at 31%, so Friday and Monday drop from 20% to 14.5%.
        let summary = try XCTUnwrap(LivePaceDisplay.futureSummary(live(used: 26, rate: 2.5, at: "14:00")))
        XCTAssertEqual(summary.days, "Fri and Mon")
        XCTAssertEqual(summary.planned, "20.0%")
        XCTAssertEqual(summary.budget, "14.5%")
        XCTAssertNil(LivePaceDisplay.futureSummary(live(used: 12, rate: 4, at: "11:30")))
        XCTAssertNil(LivePaceDisplay.futureSummary(live(used: 26, rate: 2.5, at: "14:00", futureDays: [])))
    }

    func testDayLabelsAreEnglishAndRangesSpanThreeDaysOrMore() {
        XCTAssertEqual(LivePaceFormat.dayLabel("2026-11-05", today: "2026-11-05"), "Today")
        XCTAssertEqual(LivePaceFormat.dayLabel("2026-11-06", today: "2026-11-05"), "Fri")
        XCTAssertEqual(LivePaceFormat.dayRange(["2026-11-06"]), "Fri")
        XCTAssertEqual(LivePaceFormat.dayRange(["2026-11-04", "2026-11-05", "2026-11-06", "2026-11-09"]), "Wed–Mon")
        XCTAssertEqual(LivePaceFormat.dayRange([]), "")
    }

    // MARK: - Week boxes

    private func day(_ day: String, _ percent: Double? = nil, working: Bool = true) -> TeamPlanBudget.Day {
        .init(day: day, percent: percent, working: working, estimated: false)
    }

    func testTheWeekShowsTodayFilledTheDaysLeftAtTheirBudgetAndOffDays() {
        let days = [day("2026-11-04", 10), day("2026-11-05", 5), day("2026-11-06"), day("2026-11-07", working: false), day("2026-11-09")]
        let boxes = WeekBox.boxes(
            days: days, today: "2026-11-05", used: 5, budget: 20,
            future: [("2026-11-06", 20, 20), ("2026-11-09", 20, 20)], labelsLowered: false
        )
        XCTAssertEqual(boxes.map(\.label), ["Wed", "Today", "Fri", "Sat", "Mon"])
        XCTAssertEqual(boxes.map(\.kind), [
            .past(fill: 0.5, estimated: false, label: "10.0%"), .today(fill: 0.25, overflow: 0),
            .future(height: 1, lowered: false, label: nil), .off, .future(height: 1, lowered: false, label: nil),
        ])
    }

    func testOverTheBudgetTodaySpillsOverAndTheLoweredDaysAreLabeled() {
        let days = [day("2026-11-05", 26), day("2026-11-06"), day("2026-11-09")]
        let boxes = WeekBox.boxes(
            days: days, today: "2026-11-05", used: 26, budget: 20,
            future: [("2026-11-06", 14.5, 20), ("2026-11-09", 14.5, 20)], labelsLowered: true
        )
        guard case let .today(fill, overflow) = boxes[0].kind else { return XCTFail("today") }
        XCTAssertEqual(fill, 1)
        XCTAssertEqual(overflow, 0.3, accuracy: 0.0001)
        XCTAssertEqual(boxes[1].kind, .future(height: 0.725, lowered: true, label: "14.5%"))
        // Without the label (ahead, not over yet) the lowered day is still drawn lower and orange.
        let unlabeled = WeekBox.boxes(days: days, today: "2026-11-05", used: 12, budget: 20, future: [("2026-11-06", 16, 20)], labelsLowered: false)
        XCTAssertEqual(unlabeled[1].kind, .future(height: 0.8, lowered: true, label: nil))
        XCTAssertEqual(unlabeled[2].kind, .off, "a working day with no hours has nothing to spend")
    }

    /// A heavy day tops out at the box's ceiling, as tall as a lighter heavy day: only its figure tells them apart.
    func testPastDaysCarryTheirUseEvenPastTheBoxCeiling() {
        let days = [
            TeamPlanBudget.Day(day: "2026-11-03", percent: 41, working: true, estimated: false),
            TeamPlanBudget.Day(day: "2026-11-04", percent: 24, working: true, estimated: true),
            day("2026-11-05", 24),
        ]
        let boxes = WeekBox.boxes(days: days, today: "2026-11-05", used: 24, budget: 14.9, future: [], labelsLowered: false)
        XCTAssertEqual(boxes[0].kind, .past(fill: WeekBox.maxHeight, estimated: false, label: "41.0%"))
        XCTAssertEqual(boxes[1].kind, .past(fill: WeekBox.maxHeight, estimated: true, label: "~24.0%"))
    }

    // MARK: - Team headers

    func testPlansAreGroupedOncePerTeam() {
        let groups = TeamWeekStripCard.groups(["a1", "b1", "a2"]) { String($0.prefix(1)) }
        XCTAssertEqual(groups.map(\.teamID), ["a", "b"])
        XCTAssertEqual(groups.map(\.rows), [["a1", "a2"], ["b1"]])
        XCTAssertEqual(TeamWeekStripCard.headers(["a"], selectedTeamID: "a"), .none)
        XCTAssertEqual(TeamWeekStripCard.headers(["b"], selectedTeamID: "a"), .title("b"))
        XCTAssertEqual(TeamWeekStripCard.headers(["a", "b"], selectedTeamID: "a"), .perGroup)
    }
}
