import XCTest
@testable import GodUsage

@MainActor
final class TeamsStoreTests: XCTestCase {
    private var api: FakeTeamsAPI!
    private var sessions: InMemoryTeamsSessionStore!
    private var signIn: FakeAppleSignIn!
    private var deviceID: String?

    override func setUp() async throws {
        api = FakeTeamsAPI()
        sessions = InMemoryTeamsSessionStore()
        signIn = FakeAppleSignIn()
        deviceID = "device-0001"
    }

    private func makeStore() -> TeamsStore {
        TeamsStore(
            api: api,
            sessionStore: sessions,
            signInProvider: signIn,
            historySources: { [] },
            deviceID: { [unowned self] in self.deviceID },
            deviceName: "Test Mac",
            now: { Date(timeIntervalSince1970: 1_791_200_000) },
            uploadDebounce: .zero,
            minimumUploadInterval: 900
        )
    }

    func testSignInSavesTheSessionAndLoadsTeams() async {
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: .member, memberCount: 3)]
        let store = makeStore()
        await store.signIn()

        XCTAssertEqual(api.signInCalls, [FakeTeamsAPI.SignInCall(code: "one-time-code", codeVerifier: "verifier")])
        XCTAssertEqual(store.user?.displayName, "Fede")
        XCTAssertEqual(store.teams.map(\.id), ["t1"])
        XCTAssertEqual(sessions.saved?.token, "session")
        XCTAssertNil(store.errorMessage)
    }

    func testCancelledSignInShowsNoError() async {
        signIn.error = AppleSignInError.cancelled
        let store = makeStore()
        await store.signIn()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.errorMessage)
    }

    func testAnExpiredSessionSignsOutWithAMessage() async {
        sessions.saved = TeamsSession(token: "old", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.meError = TeamsAPIError(kind: .unauthorized, message: "Sign in again.")
        let store = makeStore()
        XCTAssertTrue(store.isSignedIn)

        await store.refresh()

        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(sessions.saved)
        XCTAssertEqual(store.errorMessage, "Your teams sign-in ended. Sign in again.")
    }

    func testSignOutRemovesThisMacsUsageFirst() async {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let store = makeStore()
        await store.signOut()
        XCTAssertEqual(api.log, ["deleteDevice device-0001", "signOut"])
        XCTAssertFalse(store.isSignedIn)
    }

    func testSignOutStaysSignedInWhenRemovingUsageFails() async {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.deleteDeviceError = TeamsAPIError(kind: .network, message: "Offline.")
        let store = makeStore()
        await store.signOut()
        XCTAssertTrue(store.isSignedIn, "signing out must not strand this Mac's usage on the server")
        XCTAssertEqual(store.errorMessage, "Offline.")
    }

    func testUploadWaitsForADurableDeviceID() async {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        deviceID = nil
        let store = makeStore()
        await store.uploadNow()
        XCTAssertTrue(api.uploads.isEmpty)
        XCTAssertNotNil(store.uploadError)

        deviceID = "device-0001"
        await store.uploadNow()
        XCTAssertEqual(api.uploads.map(\.deviceID), ["device-0001"])
        XCTAssertEqual(api.uploads.first?.upload.deviceName, "Test Mac")
        XCTAssertNil(store.uploadError)
    }

    func testScheduledUploadsAreThrottledUnlessForced() async throws {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: .member, memberCount: 2)]
        let store = makeStore()
        await store.refresh() // loads teams and schedules the first upload
        try await waitUntil { self.api.uploads.count == 1 }

        store.scheduleUpload()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(api.uploads.count, 1, "a second upload inside the interval is skipped")

        store.scheduleUpload(force: true)
        try await waitUntil { self.api.uploads.count == 2 }
    }

    func testNoUploadsWithoutATeam() async throws {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        let store = makeStore()
        await store.refresh()
        store.scheduleUpload()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(api.uploads.isEmpty)
    }

    func testAnInviteReceivedWhileSignedOutIsShownAfterSignIn() async throws {
        let store = makeStore()
        let received = await store.receiveInvite("godusage://join/AbC_123-xyz0")
        XCTAssertTrue(received)
        XCTAssertEqual(store.pendingInvite?.code, "AbC_123-xyz0")
        XCTAssertNil(store.pendingInvite?.preview)

        await store.signIn()
        XCTAssertEqual(store.pendingInvite?.preview?.team.name, "Crew")

        await store.acceptPendingInvite()
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(store.teams.map(\.name), ["Crew"])
        XCTAssertEqual(store.details["t1"]?.members.count, 2)
    }

    func testAnExpiredInviteClearsWithItsMessage() async {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.inviteError = TeamsAPIError(kind: .notFound, message: "This invite link is no longer valid.")
        let store = makeStore()
        await store.receiveInvite("AbC_123-xyz0")
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(store.errorMessage, "This invite link is no longer valid.")
    }

    func testLeavingForgetsTheTeam() async {
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.teamsResult = [TeamSummary(id: "t1", name: "Crew", role: .member, memberCount: 2)]
        let store = makeStore()
        await store.refresh()
        await store.leaveTeam("t1")
        XCTAssertTrue(store.teams.isEmpty)
        XCTAssertTrue(api.log.contains("removeMember t1 u1"))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

// MARK: - Fakes

@MainActor
final class InMemoryTeamsSessionStore: TeamsSessionStoring {
    var saved: TeamsSession?
    func load() throws -> TeamsSession? { saved }
    func save(_ session: TeamsSession?) throws { saved = session }
}

@MainActor
final class FakeAppleSignIn: AppleSignInProviding {
    var error: Error?
    func signIn() async throws -> AppleSignInResult {
        if let error { throw error }
        return AppleSignInResult(code: "one-time-code", codeVerifier: "verifier")
    }
}

final class FakeTeamsAPI: TeamsAPI, @unchecked Sendable {
    struct SignInCall: Equatable {
        var code: String
        var codeVerifier: String
    }

    var signInCalls: [SignInCall] = []
    var log: [String] = []
    var uploads: [(deviceID: String, upload: TeamUsageUpload)] = []
    var teamsResult: [TeamSummary] = []
    var meError: Error?
    var deleteDeviceError: Error?
    var inviteError: Error?

    private let crew = TeamDetail(
        id: "t1",
        name: "Crew",
        role: .member,
        createdAt: "2026-10-05T00:00:00Z",
        inviteURL: URL(string: "https://api.example/join/AbC_123-xyz0")!,
        publicBoardURL: nil,
        members: [
            TeamMember(id: "owner", displayName: "Owner", role: .owner, joinedAt: "2026-10-05T00:00:00Z"),
            TeamMember(id: "u1", displayName: "Fede", role: .member, joinedAt: "2026-10-05T00:00:00Z"),
        ]
    )

    func exchangeAppleSignIn(code: String, codeVerifier: String) async throws -> TeamsSession {
        signInCalls.append(SignInCall(code: code, codeVerifier: codeVerifier))
        return TeamsSession(token: "session", user: TeamsUser(id: "u1", displayName: "Fede"))
    }

    func signOut(token: String) async throws { log.append("signOut") }

    func me(token: String) async throws -> TeamsUser {
        if let meError { throw meError }
        return TeamsUser(id: "u1", displayName: "Fede")
    }

    func rename(token: String, displayName: String) async throws -> TeamsUser { TeamsUser(id: "u1", displayName: displayName) }
    func deleteAccount(token: String) async throws { log.append("deleteAccount") }
    func teams(token: String) async throws -> [TeamSummary] { teamsResult }
    func team(token: String, id: String) async throws -> TeamDetail { crew }
    func createTeam(token: String, name: String) async throws -> TeamDetail { crew }
    func updateTeam(token: String, id: String, name: String?, publicBoard: Bool?) async throws -> TeamDetail { crew }
    func deleteTeam(token: String, id: String) async throws { log.append("deleteTeam \(id)") }
    func rotateInvite(token: String, teamID: String) async throws -> TeamDetail { crew }

    func removeMember(token: String, teamID: String, userID: String) async throws {
        log.append("removeMember \(teamID) \(userID)")
    }

    func invite(token: String, code: String) async throws -> InvitePreview {
        if let inviteError { throw inviteError }
        return InvitePreview(team: .init(id: "t1", name: "Crew", memberCount: 1), alreadyMember: false)
    }

    func acceptInvite(token: String, code: String) async throws -> TeamDetail { crew }

    func stats(token: String, teamID: String, range: StatsRange, sort: StatsSort, today: String) async throws -> TeamStatsResponse {
        throw TeamsAPIError(kind: .server, message: "unused")
    }

    func uploadUsage(token: String, deviceID: String, upload: TeamUsageUpload) async throws {
        uploads.append((deviceID, upload))
    }

    func deleteDevice(token: String, deviceID: String) async throws {
        if let deleteDeviceError { throw deleteDeviceError }
        log.append("deleteDevice \(deviceID)")
    }
}
