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
