import XCTest
@testable import GodUsage

/// Every refresh reads plain `/api/oauth/usage`; the reset-grants variant (`?cedar_ember=1&skip_spend=1`)
/// is asked at most once an hour per login. Polling it every refresh came with sustained 429s.
@MainActor
final class ClaudeResetGrantsCadenceTests: XCTestCase {
    private let t0 = GodUsageISO8601.date(from: "2026-10-12T16:00:00.000Z")!

    nonisolated private static let usageBody = #"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#
    nonisolated private static let grantsBody = """
    {"cedar_ember":{"eligible":true,"grants":[
      {"id":"soon","resets_left":1,"ends_at":"2026-10-12T16:30:00Z"},
      {"id":"later","resets_left":1,"ends_at":"2026-10-30T00:00:00Z"}]}}
    """

    private func makeProvider(
        clock: CadenceClock,
        files: FakeFiles = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token-a","refreshToken":"refresh-a","subscriptionType":"max","scopes":["user:profile"]}}"#
        ]),
        grants: @escaping @Sendable () -> HTTPResponse = { HTTPResponse(statusCode: 200, headers: [:], body: Data(grantsBody.utf8)) }
    ) -> (ClaudeProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            if request.isClaudeResetGrantsCheck { return grants() }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.usageBody.utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )
        return (provider, http)
    }

    private func resets(_ snapshot: ProviderSnapshot) -> Double? {
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Rate Limit Resets") else { return nil }
        return values.first?.number
    }

    private func counts(_ http: RoutingHTTPClient) -> (usage: Int, grants: Int) {
        (http.requests.filter(\.isClaudeUsagePoll).count, http.requests.filter(\.isClaudeResetGrantsCheck).count)
    }

    func testPlainUsageEveryRefreshAndResetGrantsHourly() async {
        let clock = CadenceClock(t0)
        let (provider, http) = makeProvider(clock: clock)

        let first = await provider.refresh()
        XCTAssertEqual(resets(first), 2)
        XCTAssertTrue(http.requests.first?.isClaudeUsagePoll == true, "the bars come from the plain read")

        clock.set(t0.addingTimeInterval(5 * 60))
        let second = await provider.refresh()
        XCTAssertEqual(resets(second), 2, "the last answer is held between checks")
        XCTAssertEqual(counts(http).usage, 2)
        XCTAssertEqual(counts(http).grants, 1)

        clock.set(t0.addingTimeInterval(60 * 60))
        _ = await provider.refresh()
        XCTAssertEqual(counts(http).usage, 3)
        XCTAssertEqual(counts(http).grants, 2)
    }

    func testFailedGrantsCheckKeepsBarsAndWaitsAnHour() async {
        let clock = CadenceClock(t0)
        let (provider, http) = makeProvider(clock: clock) {
            HTTPResponse(statusCode: 429, headers: ["retry-after": "3000"], body: Data())
        }

        let first = await provider.refresh()
        XCTAssertNotNil(first.line(label: "Session"))
        XCTAssertNil(first.warning, "a grants failure never raises the rate-limit notice")
        XCTAssertNil(first.line(label: "Rate Limit Resets"))

        clock.set(t0.addingTimeInterval(30 * 60))
        let second = await provider.refresh()
        XCTAssertNil(second.warning)
        XCTAssertEqual(counts(http).usage, 2, "a grants 429 does not start the usage cooldown")
        XCTAssertEqual(counts(http).grants, 1, "a failed check counts as the hour's check")

        clock.set(t0.addingTimeInterval(61 * 60))
        _ = await provider.refresh()
        XCTAssertEqual(counts(http).grants, 2)
    }

    func testFailedRecheckKeepsThePreviousAnswer() async {
        let clock = CadenceClock(t0)
        let failing = CadenceFlag()
        let (provider, _) = makeProvider(clock: clock) {
            failing.value
                ? HTTPResponse(statusCode: 503, headers: [:], body: Data())
                : HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.grantsBody.utf8))
        }

        _ = await provider.refresh()
        failing.value = true
        clock.set(t0.addingTimeInterval(61 * 60))
        let held = await provider.refresh()
        XCTAssertEqual(resets(held), 1, "the previous grants stay, minus the reset that lapsed at 16:30")
    }

    func testHeldGrantDropsOnceItsDeadlinePasses() async {
        let clock = CadenceClock(t0)
        let (provider, http) = makeProvider(clock: clock)

        let fresh = await provider.refresh()
        XCTAssertEqual(resets(fresh), 2)
        clock.set(GodUsageISO8601.date(from: "2026-10-12T16:45:00.000Z")!)
        let held = await provider.refresh()
        XCTAssertEqual(resets(held), 1, "the 16:30 reset is gone without asking Anthropic again")
        XCTAssertEqual(counts(http).grants, 1)
    }

    func testNewLoginChecksGrantsImmediately() async {
        let clock = CadenceClock(t0)
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token-a","refreshToken":"refresh-a","subscriptionType":"max","scopes":["user:profile"]}}"#
        ])
        let (provider, http) = makeProvider(clock: clock, files: files)

        _ = await provider.refresh()
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"token-b","refreshToken":"refresh-b","subscriptionType":"max","scopes":["user:profile"]}}"#
        clock.set(t0.addingTimeInterval(5 * 60))
        _ = await provider.refresh()

        let grantTokens = http.requests.filter(\.isClaudeResetGrantsCheck).compactMap { $0.headers["Authorization"] }
        XCTAssertEqual(grantTokens, ["Bearer token-a", "Bearer token-b"], "another login never inherits the previous answer")
    }
}

private final class CadenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}

private final class CadenceFlag: @unchecked Sendable {
    var value = false
}
