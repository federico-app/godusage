import XCTest
@testable import GodUsage

/// The This Week's Limit strip and the plan suggestions follow your plans across every team you're in.
final class YourTeamPlansTests: XCTestCase {
    private func plan(
        _ id: String, provider: String = "claude", name: String = "Claude Max", includesYou: Bool = true,
        detectedPlan: String? = nil, resetsAt: String? = nil
    ) -> TeamPlanReport {
        var plan = TeamPlanReport(
            id: id, provider: provider, name: name, monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil, includesYou: includesYou,
            cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
            valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
        )
        plan.detectedPlan = detectedPlan
        plan.budget = resetsAt.map {
            TeamPlanBudget(todayPercent: 5, affordablePercent: 10, leftPercent: 60, workingDaysLeft: 3, resetsAt: $0, accounts: 1, days: [])
        }
        return plan
    }

    private func report(_ plans: [TeamPlanReport]) -> TeamPlansReport {
        TeamPlansReport(plans: plans, totals: .init(monthlyCostUSD: 0, valueUSD: 0, projectedValueUSD: 0), canEdit: false)
    }

    private func ids(_ entries: [TeamPlanEntry]) -> [String] { entries.map { "\($0.teamID)/\($0.plan.id)" } }

    func testSelectedTeamAloneShowsItsPlansUnchanged() {
        let selected = report([plan("mine"), plan("theirs", provider: "codex", includesYou: false)])
        let merged = YourTeamPlans.merge(selectedTeamID: "small", reports: [(teamID: "small", report: selected)])
        XCTAssertEqual(ids(merged), ["small/mine", "small/theirs"], "the selected team keeps plans that don't cover you too")
    }

    func testAddsAnotherTeamsPlanThatCoversYou() {
        let merged = YourTeamPlans.merge(selectedTeamID: "all", reports: [
            (teamID: "all", report: report([])),
            (teamID: "small", report: report([plan("max")])),
        ])
        XCTAssertEqual(ids(merged), ["small/max"])
    }

    func testLeavesOutAnotherTeamsPlanThatDoesNotCoverYou() {
        let merged = YourTeamPlans.merge(selectedTeamID: "all", reports: [
            (teamID: "all", report: report([plan("mine", provider: "codex")])),
            (teamID: "small", report: report([plan("colleague", includesYou: false)])),
        ])
        XCTAssertEqual(ids(merged), ["all/mine"])
    }

    func testKeepsOneCopyOfASubscriptionPreferringTheSelectedTeam() {
        let merged = YourTeamPlans.merge(selectedTeamID: "a", reports: [
            (teamID: "a", report: report([plan("a-max", name: "Claude Max")])),
            (teamID: "b", report: report([plan("b-max", name: " claude max ")])),
        ])
        XCTAssertEqual(ids(merged), ["a/a-max"])
    }

    func testTwoOtherTeamsWithTheSameSubscriptionShowItOnce() {
        let merged = YourTeamPlans.merge(selectedTeamID: "all", reports: [
            (teamID: "all", report: report([])),
            (teamID: "b", report: report([plan("b-max", name: "Max", resetsAt: "2026-11-07T10:00:00.000Z")])),
            (teamID: "c", report: report([plan("c-max", name: "Andrea's Claude", resetsAt: "2026-11-07T10:00:00.000Z")])),
        ])
        XCTAssertEqual(ids(merged), ["b/b-max"], "one account's weekly window is one subscription, whatever each owner named it")
    }

    func testDifferentPlansOfOneProviderAreBothShown() {
        let merged = YourTeamPlans.merge(selectedTeamID: "a", reports: [
            (teamID: "a", report: report([plan("work", name: "Claude Max", detectedPlan: "Max 20x")])),
            (teamID: "b", report: report([plan("personal", name: "Claude Max", detectedPlan: "Pro")])),
        ])
        XCTAssertEqual(ids(merged), ["a/work", "b/personal"], "linked to different detected plans, so not one subscription")
    }

    func testASelectedTeamPlanThatDoesNotCoverYouHidesNothing() {
        let merged = YourTeamPlans.merge(selectedTeamID: "a", reports: [
            (teamID: "a", report: report([plan("colleague", includesYou: false)])),
            (teamID: "b", report: report([plan("mine")])),
        ])
        XCTAssertEqual(ids(merged), ["a/colleague", "b/mine"])
    }

    func testWithoutSelectedTeamPlansShowsOnlyYourOtherPlans() {
        let merged = YourTeamPlans.merge(selectedTeamID: "all", reports: [
            (teamID: "b", report: report([plan("mine"), plan("colleague", provider: "codex", includesYou: false)])),
        ])
        XCTAssertEqual(ids(merged), ["b/mine"])
        XCTAssertEqual(ids(YourTeamPlans.merge(selectedTeamID: nil, reports: [(teamID: "b", report: report([plan("mine")]))])), ["b/mine"])
    }
}
