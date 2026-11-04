import XCTest
@testable import GodUsage

/// The Teams window and Settings → Teams pick their team apart from the popover's.
@MainActor
final class TeamSelectionTests: XCTestCase {
    private func makeStore() async -> TeamsStore {
        let api = FakeTeamsAPI()
        api.teamsResult = [
            TeamSummary(id: "work", name: "Work", role: .member, memberCount: 2),
            TeamSummary(id: "friends", name: "Friends", role: .member, memberCount: 2),
        ]
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let store = TeamsStore(
            api: api,
            sessionStore: sessions,
            signInProvider: FakeAppleSignIn(),
            historySources: { [] },
            deviceID: { nil },
            uploadDebounce: .zero
        )
        await store.refresh()
        return store
    }

    func testAnOwnPickWinsWithoutMovingThePopoversTeam() async {
        let store = await makeStore()
        let popover = store.selectedTeamID
        let other = store.teams.first { $0.id != popover }!.id

        XCTAssertEqual(store.teamID(preferring: other), other)
        XCTAssertEqual(store.selectedTeamID, popover)
    }

    func testAMissingOrLeftTeamFallsBackToThePopoversTeam() async {
        let store = await makeStore()
        XCTAssertEqual(store.teamID(preferring: ""), store.selectedTeamID)
        XCTAssertEqual(store.teamID(preferring: "left-team"), store.selectedTeamID)
        XCTAssertEqual(store.teamID(preferring: nil), store.selectedTeamID)
    }

    func testOpeningTheWindowOnATeamStoresItAsTheWindowsPick() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TeamSelectionTests"))
        defaults.removePersistentDomain(forName: "TeamSelectionTests")
        TeamsWindowLink.open(teamID: "friends", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: TeamsWindowLink.teamStorageKey), "friends")
        TeamsWindowLink.open(teamID: nil, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: TeamsWindowLink.teamStorageKey), "friends")
    }
}
