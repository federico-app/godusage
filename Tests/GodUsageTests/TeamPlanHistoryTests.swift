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
}
