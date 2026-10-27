import XCTest
@testable import GodUsage

final class TeamPlanChangesTests: XCTestCase {
    private let today = "2026-10-05"

    private func plan() -> TeamPlan {
        TeamPlan(id: "p", provider: "claude", name: "Max 20x", monthlyCostUSD: 200, renewalDay: 1)
    }

    func testCycleDaysFollowTheRenewalDay() {
        XCTAssertEqual(TeamPlanChanges.cycleStart(renewalDay: 12, today: today), "2026-09-12")
        XCTAssertEqual(TeamPlanChanges.nextRenewal(renewalDay: 12, today: today), "2026-10-12")
        XCTAssertEqual(TeamPlanChanges.cycleStart(renewalDay: 5, today: today), "2026-10-05")
        XCTAssertEqual(TeamPlanChanges.nextRenewal(renewalDay: 5, today: today), "2026-11-05")
        XCTAssertEqual(TeamPlanChanges.nextRenewal(renewalDay: 31, today: "2027-02-10"), "2027-02-28")
        XCTAssertEqual(TeamPlanChanges.nextRenewal(renewalDay: 1, today: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(TeamPlanChanges.addDays("2026-10-31", 1), "2026-11-01")
    }

    func testAFutureChangeKeepsTodaysTermsUntilItApplies() {
        var plan = plan()
        plan.addChange(effectiveFrom: "2026-11-01", to: TeamPlanTerms(name: "Max 5x", monthlyCostUSD: 100), today: today)
        XCTAssertEqual(plan.name, "Max 20x")
        XCTAssertEqual(plan.monthlyCostUSD, 200)
        XCTAssertEqual(plan.changes, [.init(effectiveFrom: "2026-11-01", name: "Max 5x", monthlyCostUSD: 100, previousName: "Max 20x", previousMonthlyCostUSD: 200)])
        XCTAssertNil(plan.earliestChangeDay(today: today))
    }

    func testAPastChangeAppliesNowAndCancellingItRestoresThePreviousTerms() {
        var plan = plan()
        plan.addChange(effectiveFrom: "2026-10-03", to: TeamPlanTerms(name: "Max 5x", monthlyCostUSD: 100), today: today)
        XCTAssertEqual(plan.name, "Max 5x")
        XCTAssertEqual(plan.monthlyCostUSD, 100)
        XCTAssertEqual(plan.earliestChangeDay(today: today), "2026-10-04")

        plan.addChange(effectiveFrom: "2026-11-01", to: TeamPlanTerms(name: "Pro", monthlyCostUSD: 20), today: today)
        XCTAssertEqual(plan.changes.map(\.previousName), ["Max 20x", "Max 5x"])

        // Editing the current terms edits the change in effect today, and the next change follows.
        plan.name = "Max 5x Team"
        let history = plan.priceHistory(today: today)
        XCTAssertEqual(history.base, TeamPlanTerms(name: "Max 20x", monthlyCostUSD: 200))
        XCTAssertEqual(history.changes.map(\.name), ["Max 5x Team", "Pro"])

        plan.cancelChange(effectiveFrom: "2026-10-03", today: today)
        XCTAssertEqual(plan.name, "Max 20x")
        XCTAssertEqual(plan.monthlyCostUSD, 200)
        XCTAssertEqual(plan.changes.map(\.previousName), ["Max 20x"])
    }

    func testANewChangeReplacesTheChangesAfterIt() {
        var plan = plan()
        plan.addChange(effectiveFrom: "2026-12-01", to: TeamPlanTerms(name: "Pro", monthlyCostUSD: 20), today: today)
        plan.addChange(effectiveFrom: "2026-11-01", to: TeamPlanTerms(name: "Max 5x", monthlyCostUSD: 100), today: today)
        XCTAssertEqual(plan.changes.map(\.effectiveFrom), ["2026-11-01"])
    }

    func testOnlyChangesFromTheCurrentCycleOnShow() {
        var plan = plan()
        plan.addChange(effectiveFrom: "2026-09-10", to: TeamPlanTerms(name: "Max 5x", monthlyCostUSD: 100), today: today)
        plan.addChange(effectiveFrom: "2026-10-02", to: TeamPlanTerms(name: "Max 20x", monthlyCostUSD: 200), today: today)
        XCTAssertEqual(plan.visibleChanges(today: today).map(\.effectiveFrom), ["2026-10-02"])
    }

    func testDescribesAChangeByDirectionAndTense() {
        let label = { (day: String) in day }
        let down = TeamPlan.Change(effectiveFrom: "2026-11-01", name: "Claude Max 100", monthlyCostUSD: 100, previousName: "Max", previousMonthlyCostUSD: 200)
        XCTAssertEqual(
            TeamPlanChanges.describe(down, renewalDay: 1, today: today, dayLabel: label),
            "↓ Downgrade to Claude Max 100 · $100/mo from 2026-11-01 (next renewal)"
        )
        var up = down
        up.effectiveFrom = "2026-10-03"
        up.monthlyCostUSD = 249.5
        XCTAssertEqual(TeamPlanChanges.describe(up, renewalDay: 1, today: today, dayLabel: label), "↑ Upgraded to Claude Max 100 · $249.50/mo on 2026-10-03")
    }

    func testDetectedLabelsComeFromCoveredMembersAndPrefillWhenThereIsOne() {
        let detections = [
            TeamDetectedPlan(userID: "a", provider: "claude", plan: "Max 20x", detectedAt: "", detectedOn: ""),
            TeamDetectedPlan(userID: "b", provider: "claude", plan: "max 20x", detectedAt: "", detectedOn: ""),
            TeamDetectedPlan(userID: "c", provider: "claude", plan: "Pro", detectedAt: "", detectedOn: ""),
            TeamDetectedPlan(userID: "a", provider: "codex", plan: "Plus", detectedAt: "", detectedOn: ""),
        ]
        XCTAssertEqual(TeamPlanChanges.detectedLabels(detections, provider: "claude", memberIDs: nil), ["Max 20x", "Pro"])
        let covered = TeamPlanChanges.detectedLabels(detections, provider: "claude", memberIDs: ["a", "b"])
        XCTAssertEqual(covered, ["Max 20x"])
        XCTAssertEqual(TeamPlanChanges.prefilledLink(plan(), labels: covered), "Max 20x")
        XCTAssertNil(TeamPlanChanges.prefilledLink(plan(), labels: ["Max 20x", "Pro"]))
        var linked = plan()
        linked.detectedPlan = "Pro"
        XCTAssertNil(TeamPlanChanges.prefilledLink(linked, labels: covered))
    }

    func testPlanSendsItsHistoryAndDetectedPlan() throws {
        var plan = plan()
        plan.addChange(effectiveFrom: "2026-11-01", to: TeamPlanTerms(name: "Pro", monthlyCostUSD: 20), today: today)
        plan.detectedPlan = "Max 20x"
        plan.ignoredPlans = ["Pro"]
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
        XCTAssertTrue(json.contains("\"previousName\":\"Max 20x\""))
        XCTAssertTrue(json.contains("\"detectedPlan\":\"Max 20x\""))
        XCTAssertTrue(json.contains("\"ignoredPlans\":[\"Pro\"]"))
    }

    func testDecodesChangesAndMismatchesFromTheReport() throws {
        let body = """
        {"plans":[{"id":"p1","provider":"claude","name":"Max 5x","monthlyCostUSD":100,"renewalDay":1,"memberIDs":null,"includesYou":true,
          "cycle":{"from":"2026-10-01","to":"2026-10-31","daysElapsed":5,"daysTotal":31,"daysLeft":26},
          "valueUSD":62,"projectedValueUSD":384.4,"projectedMultiple":3.61,"underused":false,"cycleCostUSD":106.45,
          "changes":[{"effectiveFrom":"2026-10-03","name":"Max 5x","monthlyCostUSD":100,"previousName":"Max 20x","previousMonthlyCostUSD":200}],
          "detectedPlan":"Max 20x","ignoredPlans":[],
          "mismatches":[{"userID":"b","displayName":"Bea","detectedPlan":"Pro","detectedAt":"2026-10-05T12:00:00Z","detectedOn":"2026-10-05"}]}],
         "totals":{"monthlyCostUSD":100,"cycleCostUSD":106.45,"valueUSD":62,"projectedValueUSD":384.4},"canEdit":true,
         "detectedPlans":[{"userID":"b","provider":"claude","plan":"Pro","detectedAt":"2026-10-05T12:00:00Z","detectedOn":"2026-10-05"}]}
        """
        let report = try JSONDecoder().decode(TeamPlansReport.self, from: Data(body.utf8))
        let plan = try XCTUnwrap(report.plans.first)
        XCTAssertEqual(plan.cycleCost, 106.45)
        XCTAssertEqual(plan.plan.changes.first?.previousMonthlyCostUSD, 200)
        XCTAssertEqual(plan.plan.detectedPlan, "Max 20x")
        XCTAssertEqual(plan.mismatches?.first?.displayName, "Bea")
        XCTAssertEqual(report.detectedPlans?.count, 1)
        XCTAssertEqual(TeamPlanChanges.mismatchMessage(plan.mismatches![0], plan: plan), "Detected Pro on Bea’s Mac. Max 5x says Max 20x ($100/mo).")
    }

    func testUploadCarriesEachFamilysDetectedPlanAndTheLocalDay() {
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        let upload = TeamUsageUpload.make(
            sources: [
                TeamHistorySource(cardID: "claude@ab12", scope: .machineLocal, history: history, plan: "Pro"),
                TeamHistorySource(cardID: "claude", scope: .machineLocal, history: history, plan: "Max 20x"),
                TeamHistorySource(cardID: "codex", scope: .machineLocal, history: history, plan: "  "),
            ],
            deviceName: "Mac",
            dayKeys: ["2026-10-04", "2026-10-05"],
            appVersion: "1.0"
        )
        XCTAssertEqual(upload.detectedPlans, [.init(provider: "claude", plan: "Max 20x")])
        XCTAssertEqual(upload.localDay, "2026-10-05")
    }
}

@MainActor
final class TeamPlanAlertTests: XCTestCase {
    private func makeStores(role: TeamRole = .owner, alerts: Bool = true, posted: @escaping (String) -> Void) async -> (TeamPlansStore, FakeTeamsAPI) {
        let api = FakeTeamsAPI()
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: role, memberCount: 2)]
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let defaults = UserDefaults(suiteName: "TeamPlanAlertTests-\(UUID().uuidString)")!
        let teams = TeamsStore(
            api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(), historySources: { [] },
            deviceID: { "device-0001" }, deviceName: "Mac", uploadDebounce: .zero, defaults: defaults
        )
        await teams.refresh()
        let plans = TeamPlansStore(
            teams: teams, api: api, changeAlertsEnabled: { alerts },
            postNotification: { _, _, _, body in posted(body); return true }, defaults: defaults
        )
        return (plans, api)
    }

    private func report(_ mismatches: [TeamPlanMismatch]) -> TeamPlansReport {
        var plan = TeamPlanReport(
            id: "p1", provider: "claude", name: "Claude Max", monthlyCostUSD: 200, renewalDay: 1, memberIDs: nil, includesYou: true,
            cycle: .init(from: "2026-10-01", to: "2026-10-31", daysElapsed: 5, daysTotal: 31, daysLeft: 26),
            valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: true
        )
        plan.detectedPlan = "Max 20x"
        plan.mismatches = mismatches
        return TeamPlansReport(plans: [plan], totals: .init(monthlyCostUSD: 200, valueUSD: 0, projectedValueUSD: 0), canEdit: true)
    }

    private func mismatch(_ user: String, _ label: String) -> TeamPlanMismatch {
        TeamPlanMismatch(userID: user, displayName: user, detectedPlan: label, detectedAt: "2026-10-05T12:00:00Z", detectedOn: "2026-10-05")
    }

    func testAlertsOncePerNewMismatchAfterTheBaseline() async {
        var posted: [String] = []
        let (plans, api) = await makeStores { posted.append($0) }
        api.plansResult = report([mismatch("Bea", "Pro")])
        await plans.checkPlanMismatches()
        XCTAssertTrue(posted.isEmpty, "mismatches already there are only recorded")

        api.plansResult = report([mismatch("Bea", "Pro"), mismatch("Cy", "Max 5x")])
        await plans.checkPlanMismatches()
        XCTAssertEqual(posted, ["Detected Max 5x on Cy’s Mac. Claude Max says Max 20x ($200/mo)."])

        await plans.checkPlanMismatches()
        XCTAssertEqual(posted.count, 1)
    }

    func testOnlyOwnersAreAlerted() async {
        var posted: [String] = []
        let (plans, api) = await makeStores(role: .member) { posted.append($0) }
        await plans.checkPlanMismatches()
        api.plansResult = report([mismatch("Bea", "Pro")])
        await plans.checkPlanMismatches()
        XCTAssertTrue(posted.isEmpty)
    }
}
