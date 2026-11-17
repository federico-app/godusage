import XCTest
@testable import GodUsage

/// Today's use that reads the same as today's budget at one decimal ("20.0% used today", "budget
/// 20.0%") is at the budget, not over it: no "0.0% over today". Same day as `LivePaceTests`: Thursday
/// 2026-11-05, working 07:00–11:00 and 12:00–16:00 UTC, a budget of 20% and 60% left; Friday and
/// Monday follow with 8 hours each.
final class LivePaceAtBudgetTests: XCTestCase {
    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func live(used: Double, rate: Double? = 2.5, at time: String = "14:00", futureDays: [TeamPlanPace.FutureDay]? = nil) -> LivePace {
        let pace = TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: futureDays ?? [.init(day: "2026-11-06", hours: 8), .init(day: "2026-11-09", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
        return LivePace(pace: pace, now: at(time))
    }

    private func entry(_ id: String, _ provider: String) -> TeamPlanEntry {
        TeamPlanEntry(teamID: "t", plan: TeamPlanReport(
            id: id, provider: provider, name: provider, monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil, includesYou: true,
            cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
            valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
        ))
    }

    func testExactlyAtTheBudgetIsUsedUpNotOver() throws {
        let live = live(used: 20)
        XCTAssertEqual(live.state, .atBudget)
        XCTAssertEqual(live.tone, .hot)

        let pill = LivePaceDisplay.pill(live, useThisNow: false)
        XCTAssertEqual(pill.text, "Today’s budget used up")
        XCTAssertEqual(pill.style, .hot, "orange tint, not the solid over-budget pill")
        let note = try XCTUnwrap(LivePaceDisplay.note(live))
        XCTAssertEqual(note.text, "Today’s budget is used up. More today comes out of the next working days.")
        XCTAssertEqual(note.style, .notice)
        XCTAssertFalse(note.text.contains("0.0%"))
        XCTAssertEqual(LivePaceDetails.chartSummary(live), "Today’s use has reached its budget: 20.0%.")

        // Nothing is taken from the days after yet: no "Wed–Mon: 20.0% → …" summary, no labels on them.
        XCTAssertNil(LivePaceDisplay.futureSummary(live))
        // The plan stays open like one ahead of pace, and no Slow Down or Room to Spare alert.
        XCTAssertFalse(LivePaceDisplay.collapses(live.state))
        XCTAssertNil(live.alert(inYourHours: true))
        // The menu bar: an orange word, not the solid "+0.0%" chip; it ranks with ahead of pace.
        XCTAssertEqual(MenuBarTeamSegment.pace(live), MenuBarSpan("Used up", .warning))
        let over = self.live(used: 26.3)
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([live, over])?.state, .overBudget)
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([self.live(used: 7, rate: 1, at: "12:30"), live])?.state, .atBudget)
        // Another provider's plan with room is suggested, as when this one runs hot.
        let claude = entry("c", "claude"), codex = entry("x", "codex")
        let room = self.live(used: 7, rate: 1, at: "12:30")
        XCTAssertEqual(TeamWeekStripCard.useThisNow([claude, codex], paces: [claude.id: live, codex.id: room]), [codex.id])

        let lastDay = self.live(used: 20, futureDays: [])
        XCTAssertEqual(lastDay.state, .atBudget)
        XCTAssertEqual(LivePaceDisplay.note(lastDay)?.text, "Today’s budget is used up, on the last working day before the reset.")
    }

    func testAnOvershootTheLabelsRoundAwayIsStillAtTheBudget() {
        let live = live(used: 20.04)
        XCTAssertEqual(live.state, .atBudget)
        XCTAssertEqual(LivePaceDisplay.pill(live, useThisNow: false).text, "Today’s budget used up")
        // The bar is full, with no sliver of striped overflow.
        let bar = TodayBarGeometry(live)
        XCTAssertEqual(bar.fill, 1)
        XCTAssertEqual(bar.overflow, 0)
        XCTAssertNil(bar.budgetTick)
        let boxes = WeekBox.boxes(
            days: [TeamPlanBudget.Day(day: "2026-11-05", percent: nil, working: true, estimated: false)],
            today: "2026-11-05", used: live.shownUsed, budget: live.budget, future: live.futureDays, labelsLowered: false
        )
        XCTAssertEqual(boxes.first?.kind, .today(fill: 1, overflow: 0))
        // Just under, reading the same, is at the budget too.
        XCTAssertEqual(self.live(used: 19.96).state, .atBudget)
        XCTAssertEqual(self.live(used: 19.9).state, .ahead)
    }

    func testAnOvershootOfOneTenthIsOver() {
        let live = live(used: 20.1)
        XCTAssertEqual(live.state, .overBudget)
        XCTAssertEqual(LivePaceDisplay.pill(live, useThisNow: false).text, "0.1% over today")
        XCTAssertEqual(LivePaceDisplay.pill(live, useThisNow: false).style, .over)
        XCTAssertEqual(MenuBarTeamSegment.pace(live), MenuBarSpan("+0.1%", .chip))
    }

    func testARealOvershootIsOverAndLowersTheDaysAfter() throws {
        let live = live(used: 26.3)
        XCTAssertEqual(live.state, .overBudget)
        XCTAssertEqual(LivePaceDisplay.pill(live, useThisNow: false).text, "6.3% over today")
        XCTAssertEqual(LivePaceDisplay.note(live)?.text, "Today’s budget is used up. The 6.3% comes out of the next working days.")
        XCTAssertNotNil(LivePaceDisplay.futureSummary(live))
        XCTAssertGreaterThan(TodayBarGeometry(live).overflow, 0)
    }
}
