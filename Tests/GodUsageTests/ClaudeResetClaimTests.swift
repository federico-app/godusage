import XCTest
@testable import GodUsage

/// Claiming a Claude reset grant: request shape, outcome decoding, and the provider's full flow, all
/// through a stub HTTP client. The real endpoint is never touched.
@MainActor
final class ClaudeResetClaimTests: XCTestCase {
    nonisolated private static let start = GodUsageISO8601.date(from: "2026-10-18T12:00:00.000Z")!
    nonisolated private static let orgUUID = "6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab"
    nonisolated private static let requestID = "11111111-2222-3333-4444-555555555555"
    nonisolated private static let grantID = "opus55-launch-promax-20260921"
    nonisolated private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static func credentials(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(token)","subscriptionType":"max","scopes":["user:profile"]}}"#
    }
    nonisolated private static let grantsBlock = """
        {"eligible":true,"at_limit":false,"grants":[{"id":"opus55-launch-promax-20260921","resets_left":1,
        "ends_at":"2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day"],"paused":false,"usable_now":true,
        "use_requires_limit":false}],"next_grant_id":"opus55-launch-promax-20260921"}
        """

    // MARK: - Request shape

    func testClaimRequestMatchesClaudeCode() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        _ = try await ClaudeUsageClient(httpClient: http).claimResetGrant(
            accessToken: "token-a", organizationUUID: Self.orgUUID,
            grantID: Self.grantID, requestID: Self.requestID, usageURL: Self.usageURL
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/api/organizations/\(Self.orgUUID)/reset_rate_limits")
        XCTAssertEqual(request.timeout, 25)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(request.headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let userAgent = try XCTUnwrap(request.headers["User-Agent"])
        XCTAssertTrue(userAgent.hasPrefix("claude-cli/") && userAgent.hasSuffix("(external, cli)"), userAgent)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(payload, ["program": "cedar_ember", "grant_id": Self.grantID, "request_id": Self.requestID])
    }

    // MARK: - Outcome decoding

    func testOutcomeTable() {
        func outcome(_ json: String, status: Int = 200) -> ResetClaimOutcome {
            ClaudeProvider.resetClaimOutcome(from: HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8)))
        }
        let cooldown = GodUsageISO8601.date(from: "2026-10-18T13:00:00Z")!
        XCTAssertEqual(outcome(#"{"result":"reset","resets_left":0,"cleared":["five_hour","seven_day"]}"#), .success)
        XCTAssertEqual(outcome(#"{"result":"already_used"}"#), .success)
        XCTAssertEqual(outcome(#"{"result":"not_limited"}"#), .nothingToReset)
        XCTAssertEqual(outcome(#"{"result":"ineligible","reason":"unknown_grant","reset":false}"#), .noCredit)
        for reason in ["no_grant", "unknown_grant", "not_next_grant"] {
            XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"\#(reason)"}"#), .noCredit, reason)
        }
        XCTAssertEqual(outcome(#"{"result":"reset_unconfirmed"}"#), .unconfirmed)
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"stamp_indeterminate"}"#), .unconfirmed)
        XCTAssertEqual(outcome(#"{"result":"cooldown","cooldown_until":"2026-10-18T13:00:00Z"}"#), .unavailableNow(until: cooldown))
        // Anthropic sends microsecond fractions on `cooldown_until`.
        guard case .unavailableNow(let fractional?) = outcome(#"{"result":"cooldown","cooldown_until":"2026-10-18T11:56:45.910978+00:00"}"#) else {
            return XCTFail("a fractional cooldown_until must parse")
        }
        XCTAssertEqual(fractional.timeIntervalSince(GodUsageISO8601.date(from: "2026-10-18T11:56:45Z")!), 0.91, accuracy: 0.01)
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"paused"}"#), .unavailableNow(until: nil))
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"low_priority_active"}"#), .unavailableNow(until: nil))
        XCTAssertEqual(outcome(#"{"result":"unavailable","reason":"not_authorized"}"#), .failed)
        XCTAssertEqual(outcome(#"{"result":"something_new"}"#), .failed)
        XCTAssertEqual(outcome("not json"), .failed)
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 429), .failed)
        XCTAssertEqual(outcome(#"{"result":"reset"}"#, status: 500), .failed)
    }

    // MARK: - Status parse

    func testStatusParseRejectsBlockWithMalformedGrant() {
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["resets_left": 1]]]))
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["id": "g"]]]))
        XCTAssertNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": ["g"]]))
        XCTAssertNotNil(ClaudeResetGrantStatus.parse(["eligible": true, "grants": [["id": "g", "resets_left": 1]]]))
    }

    func testClaimableGrantAndConfirmCopy() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.grantsBlock.utf8)) as? [String: Any])
        let status = try XCTUnwrap(ClaudeResetGrantStatus.parse(body))
        XCTAssertEqual(status.claimableGrantID, Self.grantID)
        XCTAssertEqual(status.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")

        var ineligible = status
        ineligible.eligible = false
        XCTAssertNil(ineligible.claimableGrantID)
        var noNext = status
        noNext.nextGrantID = nil
        XCTAssertNil(noNext.claimableGrantID)
        var spent = status
        spent.grants[0].resetsLeft = 0
        XCTAssertNil(spent.claimableGrantID)
    }

    // MARK: - Provider flow

    func testClaimSpendsNextGrantThenRereadsGrants() async throws {
        let refreshed = Counter()
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset","resets_left":0}"#) })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()
        let service = ClaudeResetClaimService(provider: provider, refreshAfterClaim: { refreshed.bump() })
        XCTAssertTrue(service.isClaimable)
        XCTAssertEqual(service.confirmDetail, "Refills your session and weekly limits now. This can't be undone.")

        let outcome = await service.claim(creditExpiringAt: Self.start, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        let claims = claimRequests(http)
        XCTAssertEqual(claims.map(\.url.path), ["/api/organizations/\(Self.orgUUID)/reset_rate_limits"])
        XCTAssertEqual(claims.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(try requestID(claims[0]), Self.requestID)
        XCTAssertNil(provider.resetGrantsCheck, "the spent grant must be re-read, not served from the hourly cache")
        XCTAssertFalse(service.isClaimable)
        XCTAssertEqual(refreshed.value, 1, "a claim forces a refresh so the meters reconcile")
    }

    func testFailedClaimNeverRefreshesOrRetries() async {
        let refreshed = Counter()
        let http = makeHTTP(claim: { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data("oops".utf8)) })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()
        let service = ClaudeResetClaimService(provider: provider, refreshAfterClaim: { refreshed.bump() })

        let outcome = await service.claim(creditExpiringAt: Self.start, redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(claimRequests(http).count, 1, "a failed claim is never retried automatically")
        XCTAssertEqual(refreshed.value, 0)
        XCTAssertNotNil(provider.resetGrantsCheck?.status, "a failed claim keeps the hourly check")
    }

    func testRetryAfterAnUnsettledClaimReusesItsRequestID() async throws {
        let mode = Mode()
        mode.value = "down"
        let http = makeHTTP(claim: { _ in
            switch mode.value {
            case "down": HTTPResponse(statusCode: 502, headers: [:], body: Data())
            case "throttled": HTTPResponse(statusCode: 429, headers: [:], body: Data())
            default: Self.json(#"{"result":"already_used"}"#)
            }
        })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()

        let first = await provider.claimResetGrant(redeemRequestID: "first-confirm")
        mode.value = "throttled"
        let refused = await provider.claimResetGrant(redeemRequestID: "second-confirm")
        mode.value = "ok"
        let retry = await provider.claimResetGrant(redeemRequestID: "reopened-popover")

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(refused, .failed)
        XCTAssertEqual(retry, .success)
        XCTAssertEqual(try claimRequests(http).map(requestID), ["first-confirm", "first-confirm", "first-confirm"])
        XCTAssertNil(provider.unsettledResetClaim)
    }

    func testUnconfirmedClaimKeepsItsRequestIDForTheNextTry() async throws {
        let mode = Mode()
        mode.value = "unconfirmed"
        let http = makeHTTP(claim: { _ in
            mode.value == "unconfirmed"
                ? Self.json(#"{"result":"reset_unconfirmed"}"#)
                : Self.json(#"{"result":"already_used"}"#)
        })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()

        let first = await provider.claimResetGrant(redeemRequestID: "first-confirm")
        XCTAssertEqual(first, .unconfirmed)
        XCTAssertNil(provider.resetGrantsCheck, "an unconfirmed claim may have spent the grant")
        // The post-claim refresh re-reads the same grant (Anthropic hasn't settled it yet).
        _ = await provider.refresh()
        mode.value = "ok"
        let retry = await provider.claimResetGrant(redeemRequestID: "second-confirm")

        XCTAssertEqual(retry, .success)
        XCTAssertEqual(try claimRequests(http).map(requestID), ["first-confirm", "first-confirm"])
    }

    func testClaimLiftsTheRateLimitCooldown() async {
        let mode = Mode()
        let http = makeHTTP(usageRateLimited: mode, claim: { _ in Self.json(#"{"result":"reset"}"#) })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()
        mode.value = "429"
        _ = await provider.refresh()
        let beforeClaim = http.requests.count

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)
        mode.value = ""
        _ = await provider.refresh()

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(
            http.requests.dropFirst(beforeClaim).contains(where: \.isClaudeUsagePoll),
            "the post-claim refresh must fetch live usage instead of serving the pre-claim cache"
        )
    }

    func testNoClaimWithoutAClaimableGrant() async {
        let http = makeHTTP(grants: #"{"eligible":false,"ineligible_reason":"tier","grants":[]}"#, claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()

        XCTAssertFalse(ClaudeResetClaimService(provider: provider).isClaimable)
        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)
        XCTAssertEqual(outcome, .noCredit)
    }

    func testMalformedRequestIDIsRefusedBeforeSending() async {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()

        let outcome = await provider.claimResetGrant(redeemRequestID: "not a valid id!")
        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(provider.resetGrantsCheck)
    }

    func testRefusedClaimKeepsTheCache() async {
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"not_limited","reason":null}"#) })
        let (provider, _) = makeProvider(http: http)
        _ = await provider.refresh()

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertNotNil(provider.resetGrantsCheck?.status, "a refused claim changed nothing, so the hourly check stands")
    }

    func testClaimNeverUsesAnotherLoginThanTheGrantsCheck() async {
        let http = makeHTTP(claim: { _ in
            XCTFail("must not claim with another login")
            return Self.json(#"{"result":"reset"}"#)
        })
        let (provider, files) = makeProvider(http: http)
        _ = await provider.refresh()
        files.files["/tmp/claude/.credentials.json"] = Self.credentials("token-b")

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(claimRequests(http).isEmpty)
    }

    func testCardBoundToAnAccountClaimsWithItsVerifiedOrganization() async throws {
        let state = #"{"oauthAccount":{"accountUuid":"acct","organizationUuid":"\#(Self.orgUUID)"}}"#
        let http = makeHTTP(claim: { _ in Self.json(#"{"result":"reset"}"#) })
        let (provider, _) = makeProvider(http: http, extraFiles: ["/tmp/claude/.claude.json": state])
        _ = await provider.refresh()
        let profileReads = http.requests.filter { $0.url.path == "/api/oauth/profile" }.count

        let outcome = await provider.claimResetGrant(redeemRequestID: Self.requestID)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(profileReads, 1)
        XCTAssertEqual(
            http.requests.filter { $0.url.path == "/api/oauth/profile" }.count, 1,
            "the account check already learned the organization"
        )
    }

    // MARK: - Popover

    func testPopoverKeepsTheRequestIDOnlyWhileTheClaimMayStillLand() {
        XCTAssertTrue(RateLimitResetsDetail.keepsRequestID(.failed))
        XCTAssertTrue(RateLimitResetsDetail.keepsRequestID(.unconfirmed))
        for outcome: ResetClaimOutcome in [.success, .nothingToReset, .noCredit, .unavailableNow(until: nil)] {
            XCTAssertFalse(RateLimitResetsDetail.keepsRequestID(outcome), "\(outcome)")
        }
    }

    func testPopoverBannerCopy() {
        let now = Self.start
        XCTAssertEqual(
            RateLimitResetsDetail.banner(for: .unconfirmed, now: now).text,
            "Your reset may still be going through. Check again in a minute."
        )
        XCTAssertEqual(
            RateLimitResetsDetail.banner(for: .unavailableNow(until: nil), now: now).text,
            "Resets can't be used right now."
        )
        let later = RateLimitResetsDetail.banner(for: .unavailableNow(until: now.addingTimeInterval(2 * 3600)), now: now).text
        XCTAssertTrue(later.hasPrefix("Resets can't be used right now. Try again in "), later)
        XCTAssertEqual(RateLimitResetsDetail.banner(for: .success, now: now).text, "Reset claimed. Enjoy!")
    }

    // MARK: - Helpers

    private func makeHTTP(
        grants: String = grantsBlock,
        usageRateLimited: Mode = Mode(),
        claim: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/usage" where request.isClaudeResetGrantsCheck:
                return Self.json(#"{"cedar_ember":\#(grants)}"#)
            case "/api/oauth/usage" where usageRateLimited.value == "429":
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "3600"], body: Data())
            case "/api/oauth/usage":
                return Self.json(#"{"five_hour":{"utilization":100,"resets_at":"2099-01-01T00:00:00.000Z"}}"#)
            case "/api/oauth/profile":
                return Self.json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"\#(Self.orgUUID)"}}"#)
            case "/api/organizations/\(Self.orgUUID)/reset_rate_limits":
                return claim(request)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
    }

    private func makeProvider(
        http: RoutingHTTPClient, extraFiles: [String: String] = [:]
    ) -> (ClaudeProvider, FakeFiles) {
        let files = FakeFiles(["/tmp/claude/.credentials.json": Self.credentials("token-a")].merging(extraFiles) { $1 })
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { Self.start }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { Self.start },
            pricing: { TestPricing.bundled }
        )
        return (provider, files)
    }

    private func claimRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/reset_rate_limits") }
    }

    private func requestID(_ request: HTTPRequest) throws -> String? {
        let body = try XCTUnwrap(request.body)
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["request_id"] as? String
    }

    nonisolated private static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(text.utf8))
    }
}

/// A switch the mock endpoints read, flipped between calls.
private final class Mode: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
