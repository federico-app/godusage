import XCTest
@testable import GodUsage

/// Today works 07:00–11:00 and 12:00–16:00 UTC (8 hours), with a budget of 20% and 60% left at the
/// start of the day; Friday and Monday follow with 8 hours each.
final class LivePaceTests: XCTestCase {
    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func pace(used: Double, rate: Double?, futureDays: [TeamPlanPace.FutureDay]? = nil, hours: [TeamPlanPace.Span]? = nil) -> TeamPlanPace {
        TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: hours ?? [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: futureDays ?? [.init(day: "2026-11-06", hours: 8), .init(day: "2026-11-09", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
    }

    func testAheadOfPaceSaysByHowMuchAndWhenTheBudgetRunsOut() throws {
        // 11:30, in the break: 4 of 8 hours worked, so 10% expected; 12% used at 4%/h.
        let live = LivePace(pace: pace(used: 12, rate: 4), now: at("11:30"))
        XCTAssertEqual(live.state, .ahead)
        XCTAssertEqual(live.expected, 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(live.ahead), 48 * 60, accuracy: 1)
        XCTAssertEqual(live.projected, 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(live.allowedRate), 2, accuracy: 0.001)
        // 8% left at 4%/h is 2 working hours, after the break.
        XCTAssertEqual(live.runsOutAt, at("14:00"))
        XCTAssertEqual(live.alert(inYourHours: true), .slowDown)
        XCTAssertNil(live.alert(inYourHours: false))
        // Friday and Monday share what today leaves at this pace: 60 − 28, instead of 60 − 20.
        XCTAssertEqual(live.futureDays.map(\.budget), [16, 16])
        XCTAssertEqual(live.futureDays.map(\.planned), [20, 20])
        XCTAssertEqual(LivePaceFormat.signedDuration(try XCTUnwrap(live.ahead)), "+48 min")
    }

    func testTheColorHoldsUntilThePaceIsBackUnderTheBudget() {
        // Projected 21% (105%): orange stays once there, but doesn't start there.
        let pace = pace(used: 12, rate: 2.25)
        XCTAssertEqual(LivePace(pace: pace, now: at("11:30"), previous: .ahead).state, .ahead)
        XCTAssertEqual(LivePace(pace: pace, now: at("11:30")).state, .onPace)
        // Projected 15% (75%): green stays once there.
        let slow = self.pace(used: 7, rate: 2)
        XCTAssertEqual(LivePace(pace: slow, now: at("11:30"), previous: .behind).state, .behind)
        XCTAssertEqual(LivePace(pace: slow, now: at("11:30")).state, .onPace)
    }

    func testTheFigureIsColoredOnlyWhenWhereYouAreAndWhereYouAreHeadingAgree() {
        // 11:30: 12% used against 10% expected (+48 min), and 4%/h heads over: orange.
        XCTAssertEqual(LivePace(pace: pace(used: 12, rate: 4), now: at("11:30")).tone, .hot)
        // Same +48 min, but slowed to 0.2%/h, heading to 12.8% (64%): no green for a plus.
        let slowing = LivePace(pace: pace(used: 12, rate: 0.2), now: at("11:30"))
        XCTAssertEqual(slowing.state, .behind)
        XCTAssertEqual(slowing.tone, .neutral)
        XCTAssertTrue(slowing.alertMessage(.roomToSpare, plan: "Max", resetsAt: nil, nextDays: "Fri").body.hasPrefix("48 min ahead of pace, but slowing down."))
        // Behind (−) and heading under: green.
        XCTAssertEqual(LivePace(pace: pace(used: 7, rate: 1), now: at("12:30")).tone, .cool)
        // Behind now but speeding up over the budget: no orange for a minus.
        let speeding = LivePace(pace: pace(used: 6, rate: 6), now: at("11:30"))
        XCTAssertEqual(speeding.state, .ahead)
        XCTAssertEqual(speeding.tone, .neutral)
    }

    func testTheFirstWorkingHourIsTooEarlyToJudge() {
        let live = LivePace(pace: pace(used: 5, rate: nil), now: at("07:30"))
        XCTAssertEqual(live.state, .warmingUp)
        XCTAssertNil(live.rate)
        XCTAssertNil(live.alert(inYourHours: true))
    }

    func testWithoutAReadingAnHourOldThePaceIsTodaysAverage() throws {
        let live = LivePace(pace: pace(used: 8, rate: nil), now: at("09:00"))
        XCTAssertEqual(try XCTUnwrap(live.rate), 4, accuracy: 0.001)
    }

    func testRoomToSpareFromTheMiddleOfTheDayAndMoreEagerlyOnTheLastDay() {
        // 12:30: 4.5 hours worked, 3.5 left. At 1%/h, today ends at 10.5%: 9.5 unused.
        let normal = LivePace(pace: pace(used: 7, rate: 1), now: at("12:30"))
        XCTAssertEqual(normal.state, .behind)
        XCTAssertEqual(normal.alert(inYourHours: true), .roomToSpare)
        XCTAssertTrue(normal.alertMessage(.roomToSpare, plan: "Max", resetsAt: nil, nextDays: "Fri, Mon").body.contains("moves to Fri, Mon"))
        // Too early in the day.
        XCTAssertNil(LivePace(pace: pace(used: 3, rate: 1), now: at("09:30")).alert(inYourHours: true))

        // 15 unused of 20 (75% used) is On Pace: no alert, unless it's the last day before the reset.
        let close = pace(used: 11.5, rate: 1)
        XCTAssertNil(LivePace(pace: close, now: at("12:30")).alert(inYourHours: true))
        let lastDay = LivePace(pace: pace(used: 11.5, rate: 1, futureDays: []), now: at("12:30"))
        XCTAssertTrue(lastDay.isLastDay)
        XCTAssertEqual(lastDay.alert(inYourHours: true), .roomToSpare)
        XCTAssertTrue(lastDay.alertMessage(.roomToSpare, plan: "Max", resetsAt: nil, nextDays: "").body.contains("is lost at the reset"))
    }

    func testOverBudgetLowersTheDaysAfter() {
        let live = LivePace(pace: pace(used: 26, rate: 2.5), now: at("14:00"))
        XCTAssertEqual(live.state, .overBudget)
        // 2 hours left at 2.5%/h: today ends at 31%, so Friday and Monday get (60 − 31) / 2.
        XCTAssertEqual(live.futureDays.map(\.budget), [14.5, 14.5])
    }

    func testOutsideTheWorkingDay() {
        XCTAssertEqual(LivePace(pace: pace(used: 0, rate: nil), now: at("06:00")).state, .notStarted)
        let done = LivePace(pace: pace(used: 16, rate: 0), now: at("17:00"))
        XCTAssertEqual(done.state, .dayDone)
        // 4% left unused moves on: (60 − 16) / 2.
        XCTAssertEqual(done.futureDays.map(\.budget), [22, 22])
        XCTAssertEqual(LivePace(pace: pace(used: 0, rate: nil, hours: []), now: at("12:00")).state, .dayOff)
    }

    func testAPlanWithRoomIsSuggestedWhenAnotherRunsHot() {
        func entry(_ id: String, _ provider: String) -> TeamPlanEntry {
            TeamPlanEntry(teamID: "t", plan: TeamPlanReport(
                id: id, provider: provider, name: provider, monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil, includesYou: true,
                cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
                valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
            ))
        }
        let claude = entry("c", "claude")
        let codex = entry("x", "codex")
        let hot = LivePace(pace: pace(used: 12, rate: 4), now: at("11:30"))
        let room = LivePace(pace: pace(used: 7, rate: 1), now: at("12:30"))
        XCTAssertEqual(TeamWeekStripCard.useThisNow([claude, codex], paces: [claude.id: hot, codex.id: room]), [codex.id])
        XCTAssertEqual(TeamWeekStripCard.useThisNow([claude, codex], paces: [claude.id: room, codex.id: room]), [])
    }
}
