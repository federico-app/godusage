import XCTest
@testable import GodUsage

/// Regression: `~/.claude`'s keychain item held the personal Pro account's token while
/// `~/.claude.json` still named the Team account, so the Team card showed the personal account's
/// usage. The token's account (`/api/oauth/profile`) must match the state file's before usage is
/// published under the card's name.
@MainActor
final class ClaudeAccountMismatchTests: XCTestCase {
    nonisolated private static let teamState = #"{"oauthAccount":{"accountUuid":"ACC-TEAM","organizationUuid":"ORG-TEAM","emailAddress":"dev@example.com"}}"#
    nonisolated private static let usageBody = #"{"five_hour":{"utilization":26,"resets_at":"2099-01-01T00:00:00.000Z"}}"#

    nonisolated private static func profileBody(account: String, org: String?, email: String) -> String {
        let organization = org.map { #","organization":{"uuid":"\#($0)","organization_type":"claude_pro"}"# } ?? ""
        return #"{"account":{"uuid":"\#(account)","email":"\#(email)"}\#(organization)}"#
    }

    private func makeProvider(
        files: FakeFiles,
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) },
        profile: @escaping @Sendable () -> HTTPResponse
    ) -> (ClaudeProvider, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/api/oauth/profile") { return profile() }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.usageBody.utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: clock
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: clock,
            pricing: { TestPricing.bundled }
        )
        return (provider, http)
    }

    nonisolated private static func credentials(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","subscriptionType":"pro","scopes":["user:profile"]}}"#
    }

    nonisolated private static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    private func calls(_ http: RoutingHTTPClient, _ suffix: String) -> Int {
        http.requests.filter { $0.url.path.hasSuffix(suffix) }.count
    }

    private func hasSession(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.lines.contains { $0.label == "Session" }
    }

    func testTokenFromAnotherAccountWithholdsUsageAndWarns() async {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("personal-token"),
            "/tmp/claude/.claude.json": Self.teamState
        ])
        let (provider, http) = makeProvider(files: files) {
            Self.ok(Self.profileBody(account: "ACC-PERSONAL", org: "ORG-PERSONAL", email: "me@example.com"))
        }

        let snapshot = await provider.refresh()

        XCTAssertFalse(hasSession(snapshot))
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.warning, "This login belongs to another account (me@example.com). Run `claude /login` again.")
        XCTAssertEqual(snapshot.loginRequired, true)
        XCTAssertEqual(snapshot.resolvedWarningAction, .refresh)
        XCTAssertEqual(calls(http, "/api/oauth/usage"), 0)
        let profileRequest = http.requests.first { $0.url.path.hasSuffix("/api/oauth/profile") }
        XCTAssertEqual(profileRequest?.url.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(profileRequest?.headers["Authorization"], "Bearer personal-token")

        // The answer is kept for this token: the next refresh asks nothing and still warns.
        let second = await provider.refresh()
        XCTAssertFalse(hasSession(second))
        XCTAssertNotNil(second.warning)
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 1)
    }

    func testSameAccountInAnotherOrganizationIsAMismatch() async {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("token"),
            "/tmp/claude/.claude.json": Self.teamState
        ])
        let (provider, _) = makeProvider(files: files) {
            Self.ok(Self.profileBody(account: "acc-team", org: "ORG-PERSONAL", email: "dev@example.com"))
        }

        let snapshot = await provider.refresh()

        XCTAssertFalse(hasSession(snapshot))
        XCTAssertEqual(snapshot.warning?.hasPrefix("This login belongs to another account"), true)
    }

    func testMatchingAccountPublishesUsageAndChecksOncePerToken() async {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("team-token"),
            "/tmp/claude/.claude.json": Self.teamState
        ])
        // UUIDs compare case-insensitively.
        let (provider, http) = makeProvider(files: files) {
            Self.ok(Self.profileBody(account: "acc-team", org: "org-team", email: "dev@example.com"))
        }

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertTrue(hasSession(first))
        XCTAssertNil(first.warning)
        XCTAssertTrue(hasSession(second))
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 1)
        XCTAssertEqual(calls(http, "/api/oauth/usage"), 2)

        // A re-login (new token) is checked again.
        files.files["/tmp/claude/.credentials.json"] = Self.credentials("team-token-2")
        _ = await provider.refresh()
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 2)
    }

    func testFixingTheStateFileClearsTheWarningWithoutANewProfileCall() async {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("personal-token"),
            "/tmp/claude/.claude.json": Self.teamState
        ])
        let (provider, http) = makeProvider(files: files) {
            Self.ok(Self.profileBody(account: "ACC-PERSONAL", org: "ORG-PERSONAL", email: "me@example.com"))
        }
        let mismatched = await provider.refresh()
        XCTAssertNotNil(mismatched.warning)

        // Claude Code rewrites the state file to name the token's real account.
        files.files["/tmp/claude/.claude.json"] =
            #"{"oauthAccount":{"accountUuid":"ACC-PERSONAL","organizationUuid":"ORG-PERSONAL"}}"#
        let fixed = await provider.refresh()

        XCTAssertTrue(hasSession(fixed))
        XCTAssertNil(fixed.warning)
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 1)
    }

    func testFailedProfileLookupPublishesUsageAndRetriesAfterCooldown() async {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MutableClock(t0)
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("token"),
            "/tmp/claude/.claude.json": Self.teamState
        ])
        let (provider, http) = makeProvider(files: files, clock: { clock.now }) {
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }

        let first = await provider.refresh()
        XCTAssertTrue(hasSession(first))
        XCTAssertNil(first.warning)

        clock.set(t0.addingTimeInterval(5 * 60))
        _ = await provider.refresh()
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 1)

        clock.set(t0.addingTimeInterval(ClaudeAccountVerifier.retryCooldown + 1))
        _ = await provider.refresh()
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 2)
    }

    func testStateFileWithoutAccountSkipsTheCheck() async {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": Self.credentials("token"),
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_5x"}}"#
        ])
        let (provider, http) = makeProvider(files: files) {
            Self.ok(Self.profileBody(account: "OTHER", org: nil, email: "x@example.com"))
        }

        let snapshot = await provider.refresh()

        XCTAssertTrue(hasSession(snapshot))
        XCTAssertEqual(calls(http, "/api/oauth/profile"), 0)
    }

    func testStateFileReaderReturnsIdentityWithoutPlanFields() {
        let reader = ClaudeProfilePlanReader(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/tmp/claude/.claude.json": Self.teamState]),
            scope: .configDir(path: "/tmp/claude", keychainLiteral: "/tmp/claude")
        )

        let profile = reader.read()

        XCTAssertNil(profile?.subscriptionType)
        XCTAssertNil(profile?.rateLimitTier)
        XCTAssertEqual(profile?.account, ClaudeAccountIdentity(
            accountUUID: "ACC-TEAM", organizationUUID: "ORG-TEAM", email: "dev@example.com"
        ))
    }

    func testIdentityComparisonIgnoresAMissingOrganization() {
        let withOrg = ClaudeAccountIdentity(accountUUID: "a", organizationUUID: "o1", email: nil)
        let withoutOrg = ClaudeAccountIdentity(accountUUID: "A", organizationUUID: nil, email: nil)
        let otherOrg = ClaudeAccountIdentity(accountUUID: "a", organizationUUID: "o2", email: nil)

        XCTAssertTrue(withOrg.isSameAccount(as: withoutOrg))
        XCTAssertFalse(withOrg.isSameAccount(as: otherOrg))
        XCTAssertNil(ClaudeAccountIdentity.fromProfileResponse(Data(#"{"five_hour":{}}"#.utf8)))
    }
}

private final class MutableClock: @unchecked Sendable {
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
