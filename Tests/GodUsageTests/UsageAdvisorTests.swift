import XCTest
@testable import GodUsage

final class UsageAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86400

    private func weekly(_ family: String, used: Double, resetsIn: TimeInterval) -> UsageAdvisor.Quota {
        var data = WidgetData(title: "Weekly", icon: .providerMark(family), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetsIn)
        data.periodDurationMs = Int(week * 1000)
        return UsageAdvisor.Quota(
            providerID: family, family: family, providerName: family.capitalized, metricTitle: "Weekly", data: data
        )
    }

    private func credits(count: Int, expiresIn: [TimeInterval], spent: Bool = false) -> UsageAdvisor.ResetCredits {
        UsageAdvisor.ResetCredits(
            providerID: "codex", family: "codex", providerName: "Codex", count: count,
            expiries: expiresIn.map { now.addingTimeInterval($0) }, quotaSpent: spent
        )
    }

    private func plan(underused: Bool, daysLeft: Int) -> UsageAdvisor.Plan {
        UsageAdvisor.Plan(
            id: "p1", family: "cursor", providerName: "Cursor", name: "Cursor Pro",
            projectedMultiple: 0.4, underused: underused, daysLeft: daysLeft, cycleEnd: "2026-10-09"
        )
    }

    private func advise(
        quotas: [UsageAdvisor.Quota] = [], resets: [UsageAdvisor.ResetCredits] = [], plans: [UsageAdvisor.Plan] = []
    ) -> [UsageSuggestion] {
        UsageAdvisor.suggestions(quotas: quotas, resets: resets, plans: plans, now: now)
    }

    func testWeeklyResettingSoonWithRoomLeftSuggestsUsingIt() {
        let result = advise(quotas: [weekly("claude", used: 20, resetsIn: 86400)])
        XCTAssertEqual(result.map(\.kind), [.useBeforeReset])
        XCTAssertEqual(result.first?.family, "claude")
        XCTAssertTrue(result.first?.message.contains("resets in 1d 0h") ?? false, result.first?.message ?? "")
    }

    func testWeeklyFarFromResetSuggestsNothing() {
        XCTAssertTrue(advise(quotas: [weekly("claude", used: 10, resetsIn: 4 * 86400)]).isEmpty)
    }

    func testNearlyUsedWeeklySuggestsNothing() {
        XCTAssertTrue(advise(quotas: [weekly("claude", used: 80, resetsIn: 86400)]).isEmpty)
    }

    func testRunningOutSuggestsSwitchingToTheRoomiestProvider() {
        let result = advise(quotas: [
            weekly("claude", used: 90, resetsIn: 5 * 86400),
            weekly("codex", used: 10, resetsIn: 4 * 86400),
        ])
        XCTAssertEqual(result.map(\.kind), [.switchProvider])
        XCTAssertEqual(result.first?.title, "Switch to Codex")
    }

    func testRunningOutWithoutAnAlternativeSuggestsNothing() {
        XCTAssertTrue(advise(quotas: [weekly("claude", used: 90, resetsIn: 5 * 86400)]).isEmpty)
    }

    func testSpentWindowWithCreditsSuggestsClaimingInsteadOfSwitching() {
        let result = advise(
            quotas: [
                UsageAdvisor.Quota(
                    providerID: "codex", family: "codex", providerName: "Codex", metricTitle: "Weekly",
                    data: weekly("codex", used: 100, resetsIn: 3 * 86400).data
                ),
                weekly("claude", used: 10, resetsIn: 4 * 86400),
            ],
            resets: [credits(count: 2, expiresIn: [10 * 86400], spent: true)]
        )
        XCTAssertEqual(result.map(\.kind), [.claimReset])
    }

    func testCreditExpiringWithinTwoDaysSuggestsUsingTheProvider() {
        let result = advise(resets: [credits(count: 2, expiresIn: [30 * 86400, 10 * 3600])])
        XCTAssertEqual(result.map(\.kind), [.resetExpiring])
        XCTAssertEqual(result.first?.deadline, now.addingTimeInterval(10 * 3600))
    }

    func testManyUnexpiringCreditsSuggestLeaningOnTheProvider() {
        XCTAssertEqual(advise(resets: [credits(count: 3, expiresIn: [20 * 86400])]).map(\.kind), [.resetsAvailable])
        XCTAssertTrue(advise(resets: [credits(count: 1, expiresIn: [20 * 86400])]).isEmpty)
        XCTAssertTrue(advise(resets: [credits(count: 0, expiresIn: [])]).isEmpty)
    }

    func testUnderusedPlanNearRenewalSuggestsUsingIt() {
        XCTAssertEqual(advise(plans: [plan(underused: true, daysLeft: 3)]).map(\.kind), [.planUnderused])
        XCTAssertTrue(advise(plans: [plan(underused: true, daysLeft: 12)]).isEmpty)
        XCTAssertTrue(advise(plans: [plan(underused: false, daysLeft: 3)]).isEmpty)
    }

    func testSuggestionsAreRankedByUrgency() {
        let result = advise(
            quotas: [weekly("claude", used: 20, resetsIn: 86400)],
            resets: [credits(count: 1, expiresIn: [5 * 3600])],
            plans: [plan(underused: true, daysLeft: 2)]
        )
        XCTAssertEqual(result.map(\.kind), [.resetExpiring, .useBeforeReset, .planUnderused])
    }

    func testIDStaysStableWhileTheSituationLasts() {
        let first = advise(quotas: [weekly("claude", used: 20, resetsIn: 86400)])
        let later = UsageAdvisor.suggestions(
            quotas: [weekly("claude", used: 25, resetsIn: 86400)], resets: [], plans: [],
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(first.first?.id, later.first?.id)
    }
}
