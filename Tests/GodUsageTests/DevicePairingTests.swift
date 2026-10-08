import XCTest
@testable import GodUsage

@MainActor
final class DevicePairingTests: XCTestCase {
    private var api: FakeTeamsAPI!
    private var sessions: InMemoryTeamsSessionStore!
    private let now = Date(timeIntervalSince1970: 1_791_200_000)
    private let server = URL(string: "https://api-dev.godusage.com")!

    override func setUp() async throws {
        api = FakeTeamsAPI()
        sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "session", user: TeamsUser(id: "u1", displayName: "Fede"))
    }

    private func makeStore() -> (DevicePairingStore, TeamsStore) {
        let teams = TeamsStore(
            api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(),
            historySources: { [] }, deviceID: { nil }, deviceName: "Test Mac",
            now: { [now] in now }, uploadDebounce: .zero, minimumUploadInterval: 900
        )
        let pairing = DevicePairingStore(teams: teams, api: api, server: server, now: { [now] in now }, pollInterval: .zero)
        return (pairing, teams)
    }

    private func code(expiresIn seconds: TimeInterval) -> PairingCode {
        // The server's format: `Date.prototype.toISOString()`.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PairingCode(code: "abc", expiresAt: formatter.string(from: now.addingTimeInterval(seconds)))
    }

    func testLinkCarriesTheCodeAndTheServer() {
        let url = DevicePairingLink.url(code: "A_b-1", server: server)
        XCTAssertEqual(url.scheme, "godusage")
        XCTAssertEqual(url.host, "pair")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "code", value: "A_b-1"), URLQueryItem(name: "server", value: "https://api-dev.godusage.com")])
    }

    func testShowCodeParsesTheServerExpiry() async throws {
        api.pairingCodes = [code(expiresIn: 180)]
        let (pairing, _) = makeStore()
        await pairing.showCode()
        let active = try XCTUnwrap(pairing.activeCode)
        XCTAssertEqual(active.expiresAt.timeIntervalSince1970, now.addingTimeInterval(180).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(active.url, DevicePairingLink.url(code: "abc", server: server))
        XCTAssertNil(pairing.errorMessage)
    }

    func testWatchingHidesTheCodeOnceANewDeviceLinks() async {
        let phone = LinkedDevice(id: "h1", name: "iPhone", linkedAt: "2026-10-08T00:00:00.000Z")
        api.linkedDevicesResults = [[], [], [phone]]
        api.pairingCodes = [code(expiresIn: 180)]
        let (pairing, _) = makeStore()
        await pairing.loadDevices()
        await pairing.showCode()
        await pairing.watchForNewDevice()
        XCTAssertNil(pairing.activeCode)
        XCTAssertEqual(pairing.justLinked, phone)
        XCTAssertEqual(pairing.linkedDevices, [phone])
    }

    func testWatchingStopsAndHidesAnExpiredCode() async {
        api.pairingCodes = [code(expiresIn: -1)]
        let (pairing, _) = makeStore()
        await pairing.showCode()
        await pairing.watchForNewDevice()
        XCTAssertNil(pairing.activeCode)
        XCTAssertNil(pairing.justLinked)
    }

    func testUnlinkTreatsAnAlreadyGoneDeviceAsUnlinked() async {
        let phone = LinkedDevice(id: "h1", name: "iPhone", linkedAt: "2026-10-08T00:00:00.000Z")
        api.linkedDevicesResults = [[phone]]
        api.unlinkError = TeamsAPIError(kind: .notFound, message: "gone")
        let (pairing, _) = makeStore()
        await pairing.loadDevices()
        await pairing.unlink(phone)
        XCTAssertEqual(pairing.linkedDevices, [])
        XCTAssertNil(pairing.errorMessage)
        XCTAssertEqual(api.log, ["unlink h1"])
    }

    func testAnEndedSessionSignsTheMacOut() async {
        api.linkedDevicesError = TeamsAPIError(kind: .unauthorized, message: "Sign in again.")
        api.meError = TeamsAPIError(kind: .unauthorized, message: "Sign in again.")
        let (pairing, teams) = makeStore()
        await pairing.loadDevices()
        XCTAssertFalse(teams.isSignedIn)
    }
}
