import XCTest
@testable import GodUsage

final class TeamProjectionTests: XCTestCase {
    func testStretchesSpendSoFarOverTheMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // $50 in the first 5 days of October (31 days) → $310.
        let projection = try XCTUnwrap(TeamProjection.make(spentSoFar: 50, from: "2026-10-01", to: "2026-10-05", calendar: calendar))
        XCTAssertEqual(projection.projected, 310, accuracy: 0.001)
        XCTAssertEqual(projection.daysLeft, 26)
        // On the last day the projection is what was spent.
        let last = try XCTUnwrap(TeamProjection.make(spentSoFar: 80, from: "2026-02-01", to: "2026-02-28", calendar: calendar))
        XCTAssertEqual(last.projected, 80, accuracy: 0.001)
        XCTAssertEqual(last.daysLeft, 0)
    }

    private func challenge(winners: [ChallengeStanding], kind: ChallengeKind = .lowestSpend) -> TeamChallenge {
        TeamChallenge(id: "c", kind: kind, startsOn: "2026-10-01", endsOn: "2026-10-07", createdBy: nil, finished: true, daysLeft: 0, standings: winners, winners: winners)
    }

    func testChallengeResultMessages() throws {
        let bea = ChallengeStanding(userID: "bea", displayName: "Bea", rank: 1, value: 2)
        let other = try XCTUnwrap(TeamProjection.challengeResultMessage(challenge(winners: [bea]), me: "me"))
        XCTAssertEqual(other.title, "Bea Won Lowest Spend")
        XCTAssertEqual(other.body, "Bea finished first with $2.00.")

        let mine = try XCTUnwrap(TeamProjection.challengeResultMessage(challenge(winners: [ChallengeStanding(userID: "me", displayName: "Fede", rank: 1, value: 4)], kind: .mostModels), me: "me"))
        XCTAssertEqual(mine.title, "You Won Most Models")
        XCTAssertEqual(mine.body, "You finished first with 4 models.")

        let nobody = try XCTUnwrap(TeamProjection.challengeResultMessage(challenge(winners: []), me: "me"))
        XCTAssertEqual(nobody.title, "Lowest Spend Ended")
    }
}

@MainActor
final class TeamsSocialStoreTests: XCTestCase {
    private func makeStores(alerts: Bool = false, posted: @escaping (String) -> Void = { _ in }) async -> (TeamsStore, TeamsSocialStore, FakeTeamsAPI) {
        let api = FakeTeamsAPI()
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: .member, memberCount: 2)]
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let defaults = UserDefaults(suiteName: "TeamsSocialStoreTests-\(UUID().uuidString)")!
        let teams = TeamsStore(
            api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(), historySources: { [] },
            deviceID: { "device-0001" }, deviceName: "Mac", uploadDebounce: .zero, defaults: defaults
        )
        await teams.refresh()
        let social = TeamsSocialStore(
            teams: teams, api: api, challengeAlertsEnabled: { alerts },
            postNotification: { _, title, _, _ in posted(title); return true }, defaults: defaults
        )
        return (teams, social, api)
    }

    func testToggleAppliesAtOnceThenTakesTheServerCounts() async {
        let (_, social, api) = await makeStores()
        await social.toggle(.fire, teamID: "t1", userID: "ada")
        XCTAssertEqual(api.reactionCalls.map(\.2), [true])
        XCTAssertEqual(social.reactions(teamID: "t1", userID: "ada"), MemberReactions(fire: 3, clap: 0, clown: 0, mine: [.fire]))

        await social.toggle(.fire, teamID: "t1", userID: "ada")
        XCTAssertEqual(api.reactionCalls.map(\.2), [true, false])
        XCTAssertEqual(social.reactions(teamID: "t1", userID: "ada").mine, [])
    }

    func testChallengeResultsAlertOnceAfterTheBaseline() async {
        var posted: [String] = []
        let (_, social, api) = await makeStores(alerts: true) { posted.append($0) }
        let bea = ChallengeStanding(userID: "bea", displayName: "Bea", rank: 1, value: 2)
        let old = TeamChallenge(id: "old", kind: .lowestSpend, startsOn: "2026-09-01", endsOn: "2026-09-07", createdBy: nil, finished: true, daysLeft: 0, standings: [bea], winners: [bea])
        api.challengesResult = [old]
        await social.checkChallengeResults()
        XCTAssertTrue(posted.isEmpty, "challenges that already ended are only recorded")

        let new = TeamChallenge(id: "new", kind: .mostTokens, startsOn: "2026-09-28", endsOn: "2026-10-04", createdBy: nil, finished: true, daysLeft: 0, standings: [bea], winners: [bea])
        api.challengesResult = [new, old]
        await social.checkChallengeResults()
        XCTAssertEqual(posted, ["Bea Won Most Tokens"])

        await social.checkChallengeResults()
        XCTAssertEqual(posted.count, 1)
    }

    func testCreateAndCancelChallenges() async {
        let (_, social, api) = await makeStores()
        await social.createChallenge(teamID: "t1", kind: .mostModels, days: 14)
        XCTAssertTrue(api.log.contains("createChallenge most_models 14"))
        await social.cancelChallenge(teamID: "t1", challengeID: "c-new")
        XCTAssertTrue(api.log.contains("deleteChallenge c-new"))
    }
}

final class TeamsFormatTests: XCTestCase {
    /// Regression: sub-dollar axes (Efficiency at $0.25 steps) printed "$0 $0 $0 $1".
    func testAxisCurrencyKeepsCentsOnSmallScales() {
        let ticks = [0, 0.25, 0.5, 0.75].map(TeamsFormat.axisCurrency)
        XCTAssertEqual(Set(ticks).count, ticks.count)
        XCTAssertEqual(TeamsFormat.axisCurrency(500), Formatters.currency(500, fractionDigits: 0))
    }
}

final class TeamMetricTests: XCTestCase {
    private func member(_ name: String, tokens: Int, cost: Double, rank: Int) -> TeamStats.Member {
        TeamStats.Member(
            userID: name, displayName: name, rank: rank, tokens: tokens, costUSD: cost,
            providers: [
                .init(provider: "claude", tokens: tokens / 2, costUSD: cost * 0.75),
                .init(provider: "cursor", tokens: tokens / 2, costUSD: cost * 0.25),
            ],
            previous: nil
        )
    }

    func testCostPerMtokRanksByRateOnTheMac() {
        // Bea spends less but pays more per token, so she leads on Cost/MTok.
        let ada = member("Ada", tokens: 10_000_000, cost: 20, rank: 1)
        let bea = member("Bea", tokens: 1_000_000, cost: 5, rank: 2)
        let ranked = TeamMetric.costPerMtok.ranked([ada, bea])
        XCTAssertEqual(ranked.map(\.displayName), ["Bea", "Ada"])
        XCTAssertEqual(ranked.map(\.rank), [1, 2])
        XCTAssertEqual(TeamMetric.costPerMtok.value(bea.totals), 5, accuracy: 0.0001)
        XCTAssertEqual(TeamMetric.spend.ranked([ada, bea]).map(\.displayName), ["Ada", "Bea"])
    }

    func testCostPerMtokBarSplitsTheRateBySpendShare() {
        let ada = member("Ada", tokens: 10_000_000, cost: 20, rank: 1)
        let segments = TeamMetric.costPerMtok.barSegments(ada.providers, total: ada.totals)
        XCTAssertEqual(segments.map(\.costUSD), [1.5, 0.5])
        XCTAssertEqual(TeamMetric(StatsSort.tokens).sort, .tokens)
        XCTAssertEqual(TeamMetric(TotalSpendMetric.costPerMtok).sort, .cost)
    }
}

@MainActor
final class TeamPlansTests: XCTestCase {
    func testPlanEncodesWithoutItsLocalID() throws {
        let plan = TeamPlan(id: "local", provider: "claude", name: "Claude Max", monthlyCostUSD: 200, renewalDay: 12)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
        XCTAssertFalse(json.contains("local"))
        XCTAssertTrue(json.contains("\"renewalDay\":12"))
    }

    func testDecodesTheServerReport() throws {
        let body = """
        {"plans":[{"id":"p1","provider":"cursor","name":"Cursor Ultra","monthlyCostUSD":200,"renewalDay":1,
          "cycle":{"from":"2026-10-01","to":"2026-10-31","daysElapsed":5,"daysTotal":31,"daysLeft":26},
          "valueUSD":10,"projectedValueUSD":62,"projectedMultiple":0.31,"underused":true}],
         "totals":{"monthlyCostUSD":200,"valueUSD":10,"projectedValueUSD":62},"canEdit":false}
        """
        let report = try JSONDecoder().decode(TeamPlansReport.self, from: Data(body.utf8))
        XCTAssertEqual(report.plans.first?.plan, TeamPlan(id: "p1", provider: "cursor", name: "Cursor Ultra", monthlyCostUSD: 200, renewalDay: 1))
        XCTAssertEqual(report.plans.first?.underused, true)
        XCTAssertEqual(TeamPlansReportView.multiple(0.31), "0.3×")
        XCTAssertEqual(TeamPlansReportView.multiple(12.4), "12×")
    }

    func testDevChannelFollowsTheBundleID() {
        XCTAssertTrue(AppChannel.isDev(bundleIdentifier: "com.montinovo.godusage.dev"))
        XCTAssertFalse(AppChannel.isDev(bundleIdentifier: "com.montinovo.godusage"))
    }
}
