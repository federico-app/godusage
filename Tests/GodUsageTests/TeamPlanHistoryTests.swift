import XCTest
@testable import GodUsage

@MainActor
final class TeamPlanHistoryTests: XCTestCase {
    private let json = """
    {"plans":[{"id":"p-new","provider":"claude","name":"Claude Max","weeks":[{"from":"2026-11-03","to":"2026-11-09",
      "startsAt":"2026-11-03T03:00:00.000Z","endsAt":"2026-11-10T03:00:00.000Z","open":true,"percent":45.5,"days":[
      {"day":"2026-11-03","percent":null,"working":true,"estimated":false,"accounts":0},
      {"day":"2026-11-04","percent":19.5,"working":true,"estimated":true,"accounts":1}],
      "estimated":true,"accounts":1,"sessions":{"sessions":8,"limitHits":0,"averagePeakPercent":39}}]}],
     "workingDays":[1,2,3,4,5]}
    """

    private func plan(id: String, name: String = "Claude Max") -> TeamPlanReport {
        TeamPlanReport(
            id: id, provider: "claude", name: name, monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil, includesYou: true,
            cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
            valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
        )
    }

    func testDecodesWeeksAndMatchesAPlanByIdOrByProviderAndName() throws {
        let history = try JSONDecoder().decode(TeamPlanHistory.self, from: Data(json.utf8))
        let week = try XCTUnwrap(history.weeks(for: plan(id: "p-new"))?.first)
        XCTAssertEqual(week.days.map(\.percent), [nil, 19.5])
        XCTAssertEqual(week.percent, 45.5)
        XCTAssertTrue(week.open)
        XCTAssertEqual(week.sessions?.averagePeakPercent, 39)
        // Ids change on every save: a report from before the save still finds its plan.
        XCTAssertNotNil(history.weeks(for: plan(id: "p-old")))
        XCTAssertNil(history.weeks(for: plan(id: "p-old", name: "Claude Pro")))
    }

    func testLoadsHistoryOnRequestAndRefreshesItWithTheReport() async throws {
        let api = FakeTeamsAPI()
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: .member, memberCount: 2)]
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TeamPlanHistoryTests-\(UUID().uuidString)"))
        let teams = TeamsStore(
            api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(), historySources: { [] },
            deviceID: { "device-0001" }, deviceName: "Mac", uploadDebounce: .zero, defaults: defaults
        )
        let store = TeamPlansStore(teams: teams, api: api, defaults: defaults)
        api.historyResult = try JSONDecoder().decode(TeamPlanHistory.self, from: Data(json.utf8))

        await store.load(teamID: "t1")
        XCTAssertFalse(api.log.contains { $0.hasPrefix("planHistory") }, "history waits until a Weekly History is opened")
        await store.loadHistory(teamID: "t1")
        XCTAssertEqual(store.history(teamID: "t1")?.plans.count, 1)
        await store.load(teamID: "t1")
        XCTAssertEqual(api.log.filter { $0.hasPrefix("planHistory") }, ["planHistory t1 12", "planHistory t1 12"])

        api.historyError = TeamsAPIError(kind: .server, message: "Down")
        await store.loadHistory(teamID: "t1")
        XCTAssertNotNil(store.historyError(teamID: "t1"))
        XCTAssertNotNil(store.history(teamID: "t1"), "a failed reload keeps the weeks already shown")
    }

    func testFormatsSharesWithOneDecimalLikePerDay() {
        XCTAssertEqual(TeamPlanWeeklyHistory.number(19.5), "19.5")
        XCTAssertEqual(TeamPlanWeeklyHistory.number(100), "100")
    }

    func testBudgetNoteSaysWhatTodayCanStillUseOrHowFarOverItIs() throws {
        let json = """
        {"todayPercent":4,"affordablePercent":20.3,"leftPercent":61,"workingDaysLeft":3,"resetsAt":"2026-11-10T03:00:00.000Z",
         "accounts":1,"days":[{"day":"2026-11-03","percent":19.5,"working":true,"estimated":true}]}
        """
        var budget = try JSONDecoder().decode(TeamPlanBudget.self, from: Data(json.utf8))
        XCTAssertTrue(TeamWeekStrip.note(budget).hasPrefix("16.3% more today on budget · resets "))
        budget.todayPercent = 25
        XCTAssertTrue(TeamWeekStrip.isOverBudget(budget))
        XCTAssertTrue(TeamWeekStrip.note(budget).hasPrefix("4.7% over today's budget · resets "))
    }

    func testListsWhoReadsEachAccountOfTheWeek() throws {
        let json = """
        {"todayPercent":4,"affordablePercent":20,"leftPercent":61,"workingDaysLeft":3,"resetsAt":"2026-11-10T03:00:00.000Z","accounts":2,
         "perAccount":[{"people":["You","Matteo Scoccia"],"percent":42,"todayPercent":6,"resetsAt":"2026-11-10T03:00:00.000Z","perDevice":false},
                       {"people":["Maria Vitali"],"percent":10,"todayPercent":2,"resetsAt":"2026-11-11T09:00:00.000Z","perDevice":true}],
         "days":[]}
        """
        let budget = try JSONDecoder().decode(TeamPlanBudget.self, from: Data(json.utf8))
        let accounts = try XCTUnwrap(budget.perAccount)
        XCTAssertEqual(accounts.map(\.people), [["You", "Matteo Scoccia"], ["Maria Vitali"]])
        XCTAssertTrue(accounts[1].perDevice)
        XCTAssertEqual(TeamPlanAccountsButton.readBy(["You", "Matteo Scoccia"]), "You and Matteo Scoccia")
        XCTAssertEqual(TeamPlanAccountsButton.readBy(["A", "B", "C"]), "A, B and C")
        XCTAssertTrue(TeamPlanAccountsButton.usage(accounts[0]).hasPrefix("42.0% of the week · 6.0% today · resets "))

        // Servers before the list send none: the label stays plain text.
        let old = try JSONDecoder().decode(TeamPlanBudget.self, from: Data(json.replacingOccurrences(of: "\"perAccount\"", with: "\"ignored\"").utf8))
        XCTAssertNil(old.perAccount)
    }

    func testOwnersHideAnAccountFromAPlanAndSavingKeepsIt() async throws {
        let json = """
        {"todayPercent":4,"affordablePercent":20,"leftPercent":61,"workingDaysLeft":3,"resetsAt":"2026-11-10T03:00:00.000Z","accounts":1,
         "perAccount":[{"people":["You"],"percent":42,"todayPercent":6,"resetsAt":"2026-11-10T03:00:00.000Z","perDevice":false,"account":"aaa"}],
         "days":[]}
        """
        let budget = try JSONDecoder().decode(TeamPlanBudget.self, from: Data(json.utf8))
        XCTAssertEqual(budget.perAccount?.first?.account, "aaa")
        var report = plan(id: "p1")
        XCTAssertFalse(TeamPlanAccountsButton.isShown(budget: budget, plan: report))
        report.hiddenAccounts = ["bbb"]
        XCTAssertTrue(TeamPlanAccountsButton.isShown(budget: budget, plan: report), "one account left still lists the hidden one")
        XCTAssertEqual(TeamPlanAccountsButton.label(accounts: 1, hidden: 1), "1 account · 1 hidden")
        XCTAssertEqual(TeamPlanAccountsButton.label(accounts: 2, hidden: 0), "2 accounts")

        // Saving the list leaves them out, so the server keeps them (an editor opened before a hide can't undo it).
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.plan)) as? [String: Any]
        XCTAssertNil(encoded?["hiddenAccounts"])

        let api = FakeTeamsAPI()
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TeamPlanHistoryTests-\(UUID().uuidString)"))
        let teams = TeamsStore(
            api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(), historySources: { [] },
            deviceID: { "device-0001" }, deviceName: "Mac", uploadDebounce: .zero, defaults: defaults
        )
        let store = TeamPlansStore(teams: teams, api: api, defaults: defaults)
        let saved = await store.setAccountHidden(teamID: "t1", planID: "p1", account: "bbb", hidden: true)
        XCTAssertTrue(saved)
        XCTAssertTrue(api.log.contains("setPlanAccountHidden p1 bbb true"))
        XCTAssertNotNil(store.report(teamID: "t1"))
    }

    private func week(_ percent: Double, days: [Double?], open: Bool = false, hits: Int = 0) -> TeamPlanHistory.Week {
        TeamPlanHistory.Week(
            from: "2026-10-27", to: "2026-11-02", startsAt: "", endsAt: "2026-11-03T03:00:00.000Z", open: open, percent: percent,
            estimated: false, accounts: 1,
            days: days.enumerated().map { index, value in
                TeamPlanHistory.Day(day: "2026-10-\(27 + index)", percent: value, working: true, estimated: false, accounts: 1)
            },
            sessions: .init(sessions: 14, limitHits: hits, averagePeakPercent: 71)
        )
    }

    func testComparesTwoWeeksSideBySide() {
        let a = week(100, days: [22, 25, 18], hits: 2)
        let b = week(52, days: [10, nil, 15])
        let rows = TeamPlanWeeksCompareView.rows(a, b)
        XCTAssertEqual(rows.first, .init(label: "Weekly limit used", left: "100%", right: "52%"))
        XCTAssertEqual(rows[1], .init(label: "Limit reached", left: "Yes", right: "No"))
        XCTAssertTrue(rows[2].left.hasSuffix(" · 25%"))
        XCTAssertTrue(rows[2].right.hasSuffix(" · 15%"))
        XCTAssertEqual(rows[3], .init(label: "Sessions at the limit", left: "2 of 14", right: "0 of 14"))

        XCTAssertEqual(
            TeamPlanWeeksCompareView.summary(a, b, aName: "DEV AppLoad", bName: "Studio", samePlan: false),
            "DEV AppLoad used 48 points more of its weekly limit than Studio. The plans differ, so the shares are of different limits."
        )
        XCTAssertEqual(
            TeamPlanWeeksCompareView.summary(b, week(60, days: [], open: true), aName: "Crew", bName: "Crew", samePlan: true),
            "The second week used 8 points more of the weekly limit. One of the weeks is still running."
        )
    }
}
