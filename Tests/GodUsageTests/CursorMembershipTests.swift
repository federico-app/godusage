import XCTest
@testable import GodUsage

/// Enterprise / Team seats whose GetPlanInfo still says Pro: the badge comes from the billing
/// membership, percent-only Team totals map on the primary path, and Extra Usage (On-demand) is
/// merged from usage-summary when the primary call omits it.
final class CursorPlanResolutionTests: XCTestCase {
    func testOrgMembershipOverridesProPlanInfoForTheBadge() {
        XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: "Pro", membershipType: "enterprise"), "Enterprise")
        XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: "pro plan", membershipType: "team"), "Team")
        XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: "Ultra", membershipType: "pro"), "Ultra")
        XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: "Pro", membershipType: "pro"), "Pro")
        for plan: String? in [nil, "", "  ", "Pro", " pro plan "] {
            XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: plan, membershipType: "enterprise"), "Enterprise")
        }
        for plan in ["Ultra", "Business", "Enterprise", "Pro Plus"] {
            XCTAssertEqual(CursorUsageMapper.resolvedPlanLabel(planInfoName: plan, membershipType: "team"), plan)
        }
    }

    func testPersonalMembershipNeverFillsEmptyRoutingPlan() {
        XCTAssertNil(CursorUsageMapper.routingPlanName(planInfoName: nil, membershipType: "pro"))
        XCTAssertEqual(CursorUsageMapper.routingPlanName(planInfoName: nil, membershipType: "Enterprise"), "enterprise")
        XCTAssertEqual(CursorUsageMapper.routingPlanName(planInfoName: " Pro ", membershipType: "team"), "team")
        XCTAssertEqual(CursorUsageMapper.routingPlanName(planInfoName: " Pro ", membershipType: nil), "Pro")
    }

    func testPreferredMembershipFavorsOrgValues() {
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: "pro", summary: "enterprise"), "enterprise")
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: "enterprise", summary: "team"), "enterprise")
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: nil, summary: "pro"), "pro")
        XCTAssertNil(CursorUsageMapper.preferredMembership(local: nil, summary: nil))
    }

    func testPercentOnlyTeamPayloadStaysOnPrimaryPathAndMapsPercent() throws {
        let usage: [String: Any] = ["enabled": true, "planUsage": ["totalPercentUsed": 20]]
        XCTAssertTrue(CursorPlanUsageFacts(usage: usage).planUsageUnusable)
        for plan in ["team", "enterprise", "Team"] {
            XCTAssertFalse(CursorUsageMapper.shouldUseRequestBasedFallback(
                usage: usage, planName: plan, planInfoUnavailable: false
            ).shouldFallback)
        }
        let mapped = try CursorUsageMapper.mapUsage(usage: usage, planName: "Team", creditGrants: nil, stripeBalanceCents: 0)
        let total = try XCTUnwrap(cursorProgress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 20)
        XCTAssertEqual(total.limit, 100)
        XCTAssertEqual(total.format, .percent)
    }

    func testTeamDollarLimitStillWinsOverZeroPercentPlaceholder() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: ["enabled": true, "planUsage": ["limit": 2_000, "totalSpend": 400, "totalPercentUsed": 0]],
            planName: "Team", creditGrants: nil, stripeBalanceCents: 0
        )
        let total = try XCTUnwrap(cursorProgress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 4)
        XCTAssertEqual(total.limit, 20)
        XCTAssertEqual(total.format, .dollars)
    }

    func testAppendMissingOnDemandKeepsAnExistingRow() {
        var lines: [MetricLine] = [.progress(label: "On-demand", used: 1, limit: 10, format: .dollars)]
        CursorUsageSummaryMapper.appendMissingOnDemand(
            from: ["individualUsage": ["onDemand": ["enabled": true, "used": 25_000, "limit": 100_000]]],
            to: &lines
        )
        XCTAssertEqual(lines.filter { $0.label == "On-demand" }.count, 1)
        XCTAssertEqual(cursorProgress(lines, "On-demand")?.limit, 10)
    }

    func testSummaryFallbackBadgePrefersLiveOrgMembershipOverPro() throws {
        let mapped = try CursorUsageSummaryMapper.map(
            summary: [
                "membershipType": "enterprise",
                "individualUsage": ["plan": ["totalPercentUsed": 5]]
            ],
            requestUsage: nil,
            planName: "Pro",
            unavailableMessage: "unavailable"
        )
        XCTAssertEqual(mapped.plan, "Enterprise")
    }
}

final class CursorMembershipAuthTests: XCTestCase {
    func testSQLiteLoginCarriesLowercasedMembership() {
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: makeSharedCursorJWT(sub: "google-oauth2|enterprise-user"),
                CursorAuthStore.membershipTypeKey: "Enterprise"
            ]),
            keychain: FakeKeychain()
        )
        XCTAssertEqual(store.loadCredentials().state?.membershipType, "enterprise")
        XCTAssertEqual(store.loadCredentials().state?.source, .sqlite)
    }

    func testKeychainSessionForAnotherAccountDoesNotInheritStateDBMembership() {
        let keychainToken = makeSharedCursorJWT(sub: "google-oauth2|paid-user")
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: makeSharedCursorJWT(sub: "google-oauth2|free-user"),
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: FakeKeychain(keychainToken)
        )
        let state = store.loadCredentials().state
        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
        XCTAssertNil(state?.membershipType)
    }

    func testKeychainOnlyLoginHasNoMembership() {
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [CursorAuthStore.membershipTypeKey: "enterprise"]),
            keychain: FakeKeychain(makeSharedCursorJWT(sub: "google-oauth2|agent-user"))
        )
        XCTAssertEqual(store.loadCredentials().state?.source, .keychain)
        XCTAssertNil(store.loadCredentials().state?.membershipType)
    }
}

@MainActor
final class CursorMembershipProviderTests: XCTestCase {
    func testProPlanInfoWithLocalTeamMembershipShowsTeamWithoutChangingPrimaryTotal() async throws {
        for planUsage: [String: Any] in [
            ["limit": 2000, "totalSpend": 400, "totalPercentUsed": 20],
            ["totalPercentUsed": 20],
            ["totalPercentUsed": 20, "autoPercentUsed": 10, "apiPercentUsed": 30]
        ] {
            let body = try JSONSerialization.data(withJSONObject: ["enabled": true, "planUsage": planUsage])
            let http = RoutingHTTPClient { request in
                switch request.url {
                case CursorUsageClient.usageURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: body)
                case CursorUsageClient.planURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":" Pro "}}"#.utf8))
                default:
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }
            let snapshot = await makeProvider(http: http, membership: "team").refresh()

            XCTAssertEqual(snapshot.plan, "Team")
            let total = try XCTUnwrap(cursorProgress(snapshot.lines, "Total usage"))
            XCTAssertEqual(total.used, 20)
            XCTAssertEqual(total.limit, 100)
            XCTAssertEqual(total.format, .percent)
        }
    }

    func testPrimaryPoolPathMergesUsageSummaryOnDemandAndEnterpriseBadge() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleStart": 1770000000000,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 2000, "totalSpend": 1500,
                    "autoPercentUsed": 75, "apiPercentUsed": 100, "totalPercentUsed": 76
                  },
                  "spendLimitUsage": { "limitType": "team", "pooledLimit": 0 }
                }
                """.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            case CursorUsageClient.usageSummaryURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "membershipType": "enterprise",
                  "individualUsage": {
                    "onDemand": { "enabled": true, "used": 12345, "limit": 200000, "remaining": 187655 }
                  }
                }
                """.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        // No local membership: the team-shaped payload alone triggers the probe, and the live
        // usage-summary membership corrects the badge.
        let snapshot = await makeProvider(http: http, membership: nil).refresh()

        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertEqual(cursorProgress(snapshot.lines, "Cursor models")?.used, 75)
        XCTAssertEqual(cursorProgress(snapshot.lines, "Other models")?.used, 100)
        let onDemand = try XCTUnwrap(cursorProgress(snapshot.lines, "On-demand"))
        XCTAssertEqual(onDemand.used, 123.45, accuracy: 0.001)
        XCTAssertEqual(onDemand.limit, 2_000)
    }

    func testPersonalProSeatIsNotProbedForUsageSummary() async throws {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"enabled":true,"planUsage":{"limit":2000,"totalPercentUsed":20,"autoPercentUsed":10}}"#.utf8
                ))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let snapshot = await makeProvider(http: http, membership: "pro").refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertFalse(http.requests.contains { $0.url == CursorUsageClient.usageSummaryURL })
    }

    private func makeProvider(http: RoutingHTTPClient, membership: String?) -> CursorProvider {
        var values = [CursorAuthStore.accessTokenKey: makeSharedCursorJWT(sub: "google-oauth2|org-seat")]
        values[CursorAuthStore.membershipTypeKey] = membership
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-membership-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CursorProvider(
            authStore: CursorAuthStore(sqlite: FakeCursorSQLite(values: values), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled },
            spendHistoryBudget: 0,
            usageHistoryStore: CursorUsageHistoryStore(directory: directory)
        )
    }
}

private func cursorProgress(
    _ lines: [MetricLine],
    _ label: String
) -> (used: Double, limit: Double, format: ProgressFormat)? {
    guard case .progress(_, let used, let limit, let format, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, format)
}
