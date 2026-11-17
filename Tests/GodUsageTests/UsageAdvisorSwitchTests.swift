import XCTest
@testable import GodUsage

/// The switch suggestion's text, with and without a team plan Live Pace says to use now.
final class UsageAdvisorSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86400

    private func weekly(_ family: String, name: String, used: Double) -> UsageAdvisor.Quota {
        var data = WidgetData(title: "Weekly", icon: .providerMark(family), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(5 * 86400)
        data.periodDurationMs = Int(week * 1000)
        return UsageAdvisor.Quota(providerID: family, family: family, providerName: name, metricTitle: "Weekly", data: data)
    }

    private func switchMessage(_ roomy: [UsageAdvisor.RoomyPlan], claudeUsed: Double = 90) -> String? {
        UsageAdvisor.suggestions(
            quotas: [weekly("claude", name: "Claude (Appload)", used: claudeUsed), weekly("codex", name: "Codex", used: 0)],
            resets: [], plans: [], roomyPlans: roomy, now: now
        ).first { $0.kind == .switchProvider }?.message
    }

    func testWithoutAPlanTheWordingIsUnchanged() {
        XCTAssertEqual(
            switchMessage([]),
            "Claude (Appload) is on pace to hit its Weekly limit before it resets. Codex has 100% of its Weekly left."
        )
    }

    func testAUseThisNowPlanIsNamedWithHowFarUnderPace() {
        let plan = UsageAdvisor.RoomyPlan(family: "codex", name: "ChatGPT Plus", ahead: -(2 * 3600 + 48 * 60), leftToday: 12)
        XCTAssertEqual(
            switchMessage([plan]),
            "Claude (Appload) will hit its Weekly limit before the reset. ChatGPT Plus is 2h 48m under pace."
        )
    }

    func testAPlanOnPaceSaysWhatTodayHasLeft() {
        let plan = UsageAdvisor.RoomyPlan(family: "codex", name: "ChatGPT Plus", ahead: 60, leftToday: 7.5)
        XCTAssertEqual(
            switchMessage([plan]),
            "Claude (Appload) will hit its Weekly limit before the reset. ChatGPT Plus has 7.5% of today’s budget left."
        )
    }

    func testAPlanForAnotherProviderIsIgnored() {
        let plan = UsageAdvisor.RoomyPlan(family: "cursor", name: "Cursor Pro", ahead: -3600, leftToday: 10)
        XCTAssertEqual(
            switchMessage([plan]),
            "Claude (Appload) is on pace to hit its Weekly limit before it resets. Codex has 100% of its Weekly left."
        )
    }

    func testASpentWindowKeepsItsReason() {
        let plan = UsageAdvisor.RoomyPlan(family: "codex", name: "ChatGPT Plus", ahead: -3600, leftToday: 10)
        XCTAssertEqual(
            switchMessage([plan], claudeUsed: 100),
            "Your Claude (Appload) Weekly is used up. ChatGPT Plus is 1h 00m under pace."
        )
    }

    // MARK: Live Pace → roomy plans

    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func pace(used: Double, rate: Double?) -> TeamPlanPace {
        TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: [.init(day: "2026-11-06", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
    }

    private func entry(_ id: String, _ provider: String, name: String, includesYou: Bool = true) -> TeamPlanEntry {
        TeamPlanEntry(teamID: "t", plan: TeamPlanReport(
            id: id, provider: provider, name: name, monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil, includesYou: includesYou,
            cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
            valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
        ))
    }

    @MainActor
    func testRoomyPlansFollowTheUseThisNowRule() throws {
        let claude = entry("c", "claude", name: "Claude Team")
        let codex = entry("x", "codex", name: "ChatGPT Plus")
        let hot = LivePace(pace: pace(used: 12, rate: 4), now: at("11:30"))
        let room = LivePace(pace: pace(used: 7, rate: 1), now: at("12:30"))

        let roomy = UsageAdviceStore.roomyPlans([claude, codex], paces: [claude.id: hot, codex.id: room])
        XCTAssertEqual(roomy.map(\.name), ["ChatGPT Plus"])
        XCTAssertEqual(roomy.first?.family, "codex")
        XCTAssertEqual(try XCTUnwrap(roomy.first?.ahead), try XCTUnwrap(room.ahead))

        // Nothing runs hot: no plan to name.
        XCTAssertTrue(UsageAdviceStore.roomyPlans([claude, codex], paces: [claude.id: room, codex.id: room]).isEmpty)
        // A plan that doesn't cover you is not yours to switch to.
        let notYours = entry("x", "codex", name: "ChatGPT Plus", includesYou: false)
        XCTAssertTrue(UsageAdviceStore.roomyPlans([claude, notYours], paces: [claude.id: hot, notYours.id: room]).isEmpty)
    }
}
