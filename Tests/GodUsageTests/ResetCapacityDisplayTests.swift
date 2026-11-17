import XCTest
@testable import GodUsage

/// How a week with a claimed reset reads, and Live Pace restarting today's even pace at the claim.
final class ResetCapacityDisplayTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    func testShowsTheWeeksUseAgainstItsCapacity() {
        let week = TeamPlanBudget.WeekCapacity(usedPercent: 135, capacityPercent: 200, segments: [95, 40], resets: 1)
        XCTAssertEqual(ResetCapacityFormat.weekLine(week, locale: en), "↻ 95% + 40% of 200% this week")
        let shared = TeamPlanBudget.WeekCapacity(usedPercent: 120.5, capacityPercent: 150, segments: nil, resets: 1)
        XCTAssertEqual(ResetCapacityFormat.weekLine(shared, locale: en), "↻ 120.5% of 150% this week")
        XCTAssertEqual(ResetCapacityFormat.usedOfCapacity(used: 135, capacity: 200, locale: en), "135% of 200%")
        XCTAssertNil(ResetCapacityFormat.usedOfCapacity(used: 60, capacity: 100, locale: en), "a week without a claim reads as before")
        XCTAssertNil(ResetCapacityFormat.quotaNote(resets: nil))
        XCTAssertNotNil(ResetCapacityFormat.quotaNote(resets: 1))
    }

    func testMarksTheDayOfTheClaimInTheWeeksBoxes() {
        let days = [
            TeamPlanBudget.Day(day: "2026-11-04", percent: 30, working: true, estimated: false, resets: 1),
            TeamPlanBudget.Day(day: "2026-11-05", percent: 10, working: true, estimated: false),
        ]
        let boxes = WeekBox.boxes(days: days, today: "2026-11-05", used: 10, budget: 20, future: [], labelsLowered: false)
        XCTAssertEqual(boxes.map(\.reset), [true, false])
    }

    func testLivePaceRestartsTheEvenPaceAtAClaimMadeWhileOverBudget() throws {
        // 08:00–16:00. 30% used by the 10:00 claim (over the old budget); the new budget is 30 plus a share of what's left.
        let pace = TeamPlanPace(
            budgetPercent: 50, usedPercent: 36, leftPercent: 150, ratePerHour: 3,
            hours: [.init(from: "2026-11-05T08:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: [.init(day: "2026-11-06", hours: 8)], today: [], sharedWith: [], resetsAt: "2026-11-07T00:00:00Z",
            rebase: .init(at: "2026-11-05T10:00:00Z", usedPercent: 30)
        )
        let live = LivePace(pace: pace, now: at("13:00"))
        // Half of the 6 hours after the claim: 30 + (50 − 30) / 2.
        XCTAssertEqual(live.expected, 40, accuracy: 0.001)
        XCTAssertEqual(live.evenPace(at: at("10:00")), 30, accuracy: 0.001)
        XCTAssertEqual(live.evenPace(at: at("09:00")), 15, accuracy: 0.001)
        XCTAssertEqual(live.evenPace(at: at("16:00")), 50, accuracy: 0.001)
        // 4 points under an even pace of 20 points over 6 hours: 72 minutes behind, not over budget.
        XCTAssertEqual(try XCTUnwrap(live.ahead), -72 * 60, accuracy: 1)
        XCTAssertNotEqual(live.state, .overBudget)
    }
}
