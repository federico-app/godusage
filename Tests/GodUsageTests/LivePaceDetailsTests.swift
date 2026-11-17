import XCTest
@testable import GodUsage

/// What Live Pace Details show: the rate tiles, the hours line's initials, and where the day chart's
/// words go. Same day as `LivePaceTests`: Thursday 2026-11-05, working 07:00–11:00 and 12:00–16:00
/// UTC, a budget of 20% and 60% left.
final class LivePaceDetailsTests: XCTestCase {
    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func live(used: Double, rate: Double?, at time: String) -> LivePace {
        let pace = TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: [.init(day: "2026-11-06", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
        return LivePace(pace: pace, now: at(time))
    }

    // MARK: - Rates

    func testPaceNowTakesThePlansTone() {
        // 11:30: 10% expected, 12% used, 4%/h heads well over the budget.
        let hot = live(used: 12, rate: 4, at: "11:30")
        XCTAssertEqual(LivePaceDetails.paceNowTone(hot), .hot)
        // 12:30: 11.25% expected, 7% used, 1%/h ends well under.
        XCTAssertEqual(LivePaceDetails.paceNowTone(live(used: 7, rate: 1, at: "12:30")), .cool)
        XCTAssertEqual(LivePaceDetails.paceNowTone(live(used: 5, rate: 2.5, at: "09:00")), .neutral)
        // The first working hour is never colored.
        XCTAssertEqual(LivePaceDetails.paceNowTone(live(used: 4, rate: 8, at: "07:30")), .neutral)
    }

    func testRatesOnlyWhileThePaceMeansSomething() {
        let rates = LivePaceDetails.rates(live(used: 12, rate: 4, at: "11:30"))
        XCTAssertEqual(rates?.now, "4.0%/h")
        // 8% left over the 4 working hours after the break.
        XCTAssertEqual(rates?.allowed, "2.0%/h")
        XCTAssertEqual(rates?.until, LivePaceFormat.time(at("16:00")))
        // No rate yet in the first working hour: the tile has no value, the allowed pace still shows.
        let early = LivePaceDetails.rates(live(used: 1, rate: nil, at: "07:30"))
        XCTAssertNil(early?.now)
        XCTAssertNotNil(early?.allowed)
        XCTAssertNil(LivePaceDetails.rates(live(used: 22, rate: 4, at: "11:30")), "over budget")
        XCTAssertNil(LivePaceDetails.rates(live(used: 0, rate: nil, at: "06:00")), "not started")
        XCTAssertNil(LivePaceDetails.rates(live(used: 18, rate: 1, at: "17:00")), "day done")
    }

    // MARK: - Hours

    func testInitialsAreTheFirstLettersOfTheFirstTwoWords() {
        XCTAssertEqual(LivePaceDetails.initials("Matteo Scoccia"), "MS")
        XCTAssertEqual(LivePaceDetails.initials("maria  de la Vitali"), "MD")
        XCTAssertEqual(LivePaceDetails.initials("Federico"), "F")
        XCTAssertEqual(LivePaceDetails.initials("  "), "?")
    }

    func testHueIsStablePerName() {
        XCTAssertEqual(LivePaceDetails.hue("Matteo Scoccia"), LivePaceDetails.hue("Matteo Scoccia"))
        XCTAssertNotEqual(LivePaceDetails.hue("Matteo Scoccia"), LivePaceDetails.hue("Maria Vitali"))
        XCTAssert((0..<1).contains(LivePaceDetails.hue("Federico Mengascini")))
    }

    func testAvatarsShowThreeThenACount() {
        let names = ["Matteo Scoccia", "Maria Vitali", "Federico Mengascini", "Anna Rossi", "Luca Bianchi"]
        XCTAssertEqual(LivePaceDetails.avatars(names).shown, Array(names.prefix(3)))
        XCTAssertEqual(LivePaceDetails.avatars(names).more, 2)
        XCTAssertEqual(LivePaceDetails.avatars(Array(names.prefix(2))).more, 0)
        XCTAssertEqual(LivePaceDetails.sharedWith(Array(names.prefix(2))), "Shared with Matteo Scoccia and Maria Vitali")
    }

    func testHoursOnOneLine() {
        let spans = [DateInterval(start: at("07:00"), end: at("11:00")), DateInterval(start: at("12:00"), end: at("16:00"))]
        let hours = LivePaceDetails.hours(spans)
        XCTAssertEqual(hours.components(separatedBy: " · ").count, 2)
        XCTAssertEqual(LivePaceDetails.hours([]), "No working hours today")
    }

    // MARK: - Chart

    func testShadeFollowsWhereUseStandsNow() {
        XCTAssertEqual(LivePaceDetails.shade(live(used: 12, rate: 4, at: "11:30")), .ahead)
        XCTAssertEqual(LivePaceDetails.shade(live(used: 7, rate: 1, at: "12:30")), .behind)
        XCTAssertNil(LivePaceDetails.shade(live(used: 5, rate: 2.5, at: "09:00")), "on pace")
        XCTAssertNil(LivePaceDetails.shade(live(used: 18, rate: 1, at: "17:00")), "day done")
    }

    func testChartSummary() {
        let ahead = live(used: 12, rate: 4, at: "11:30")
        // 8% left at 4%/h: two working hours after the break, so 14:00.
        XCTAssertEqual(LivePaceDetails.chartSummary(ahead), "Today’s use is ahead of even pace; at this pace the budget runs out at \(LivePaceFormat.time(at("14:00"))).")
        XCTAssertEqual(LivePaceDetails.chartSummary(live(used: 7, rate: 1, at: "12:30")), "Today’s use is behind even pace; at this pace today ends at 10.5% of its 20.0% budget.")
        XCTAssertEqual(LivePaceDetails.chartSummary(live(used: 22, rate: 4, at: "11:30")), "Today’s use is over its budget: 22.0% of 20.0%.")
        XCTAssertEqual(LivePaceDetails.chartSummary(live(used: 18, rate: 1, at: "17:00")), "The working day is over; today used 18.0% of its 20.0% budget.")
    }

    func testCrossingSitsWhereTheBudgetRunsOut() throws {
        // 14:00 is 7 of the 9 hours from 07:00 to 16:00.
        let x = try XCTUnwrap(LivePaceChartLayout.crossing(live(used: 12, rate: 4, at: "11:30"), width: 360))
        XCTAssertEqual(x, 280, accuracy: 0.001)
        XCTAssertNil(LivePaceChartLayout.crossing(live(used: 7, rate: 1, at: "12:30"), width: 360), "never runs out")
        XCTAssertNil(LivePaceChartLayout.crossing(live(used: 22, rate: 4, at: "11:30"), width: 360), "already over")
    }

    func testCrossingLabelStaysInsideTheChart() {
        XCTAssertEqual(LivePaceChartLayout.clampedCenter(300, labelWidth: 80, in: 360), 300)
        XCTAssertEqual(LivePaceChartLayout.clampedCenter(340, labelWidth: 80, in: 360), 320)
        XCTAssertEqual(LivePaceChartLayout.clampedCenter(10, labelWidth: 80, in: 360), 40)
        XCTAssertEqual(LivePaceChartLayout.clampedCenter(10, labelWidth: 400, in: 360), 180)
    }

    func testLabelsApartAreLeftAlone() {
        XCTAssertEqual(LivePaceChartLayout.nudge([20, 60, 40], height: 10, within: 0...100), [20, 60, 40])
    }

    func testOverlappingLabelsAreNudgedApart() {
        // Budget above its line and Even pace below it, the current pace's label right on the budget.
        let centers = LivePaceChartLayout.nudge([43, 57, 50], height: 11, within: 0...100)
        let sorted = centers.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 11 - 0.0001) }
        // Order is kept, and nothing moves further than it has to.
        XCTAssertLessThan(centers[0], centers[2])
        XCTAssertLessThan(centers[2], centers[1])
        XCTAssertEqual(centers[0], 39, accuracy: 0.0001)
        XCTAssertEqual(centers[1], 61, accuracy: 0.0001)
    }

    func testNudgedLabelsStayInsideTheChart() {
        let top = LivePaceChartLayout.nudge([0, 2], height: 10, within: 0...100)
        XCTAssertEqual(top, [5, 15])
        let bottom = LivePaceChartLayout.nudge([99, 98], height: 10, within: 0...100)
        XCTAssertEqual(bottom, [95, 85])
    }

    func testRowLabelsOverlap() {
        XCTAssertTrue(LivePaceChartLayout.overlap((20, 30), (40, 20)))
        XCTAssertFalse(LivePaceChartLayout.overlap((20, 30), (60, 20)))
    }
}
