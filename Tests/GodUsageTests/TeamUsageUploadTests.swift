import XCTest
@testable import GodUsage

final class TeamUsageUploadTests: XCTestCase {
    private let window: Set<String> = ["2026-10-04", "2026-10-05"]

    private func history(
        _ days: [(String, Int, Double?)],
        models: [(String, [(String, Int, Double?)])] = []
    ) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: days.map { DailyUsageEntry(date: $0.0, totalTokens: $0.1, costUSD: $0.2) }),
            modelUsage: models.isEmpty ? nil : ModelUsageSeries(daily: models.map { date, entries in
                DailyModelUsageEntry(date: date, models: entries.map { ModelUsageEntry(model: $0.0, totalTokens: $0.1, costUSD: $0.2) })
            })
        )
    }

    func testFoldsAccountCardsIntoTheirFamilyWithoutLeakingAccountIDs() throws {
        let upload = TeamUsageUpload.make(
            sources: [
                TeamHistorySource(
                    cardID: "claude",
                    scope: .machineLocal,
                    history: history([("2026-10-05", 100, 1.0)], models: [("2026-10-05", [("claude-opus-4-1", 100, 1.0)])])
                ),
                TeamHistorySource(
                    cardID: "claude@ab12cd34",
                    scope: .machineLocal,
                    history: history([("2026-10-05", 50, 0.5)], models: [("2026-10-05", [("Claude-Opus-4-1", 50, 0.5)])])
                ),
            ],
            deviceName: "MacBook",
            dayKeys: window
        )

        XCTAssertEqual(upload.providers.count, 1)
        let claude = try XCTUnwrap(upload.providers.first)
        XCTAssertEqual(claude.provider, "claude")
        XCTAssertEqual(claude.scope, "device")
        XCTAssertEqual(claude.days, [
            .init(date: "2026-10-05", tokens: 150, costUSD: 1.5, models: [.init(model: "claude-opus-4-1", tokens: 150, costUSD: 1.5)]),
        ])
        let json = String(decoding: try JSONEncoder().encode(upload), as: UTF8.self)
        XCTAssertFalse(json.contains("ab12cd34"), "account ids must not leave the Mac")
    }

    func testAccountWideSourcesAreMarkedAccountScope() {
        let upload = TeamUsageUpload.make(
            sources: [TeamHistorySource(cardID: "cursor", scope: .accountWide, history: history([("2026-10-05", 9, 2)]))],
            deviceName: "MacBook",
            dayKeys: window
        )
        XCTAssertEqual(upload.providers.map(\.scope), ["account"])
    }

    func testDropsDaysOutsideTheWindowAndEmptyProviders() {
        let upload = TeamUsageUpload.make(
            sources: [
                TeamHistorySource(cardID: "codex", scope: .machineLocal, history: history([("2026-09-01", 5, 1), ("2026-10-04", 7, nil)])),
                TeamHistorySource(cardID: "grok", scope: .machineLocal, history: history([("2026-01-01", 5, 1)])),
            ],
            deviceName: "MacBook",
            dayKeys: window
        )
        XCTAssertEqual(upload.providers.map(\.provider), ["codex"])
        XCTAssertEqual(upload.providers.first?.days, [.init(date: "2026-10-04", tokens: 7, costUSD: nil, models: [])])
    }

    func testUnknownCostDoesNotEraseAKnownCost() {
        let upload = TeamUsageUpload.make(
            sources: [
                TeamHistorySource(cardID: "claude", scope: .machineLocal, history: history([("2026-10-05", 1, nil)])),
                TeamHistorySource(cardID: "claude@x1", scope: .machineLocal, history: history([("2026-10-05", 1, 0.25)])),
            ],
            deviceName: "MacBook",
            dayKeys: window
        )
        XCTAssertEqual(upload.providers.first?.days.first?.costUSD, 0.25)
    }

    func testEncodesTheBackendSchema() throws {
        let upload = TeamUsageUpload.make(sources: [], deviceName: "Mac", dayKeys: window)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "godusage.team-usage.v1")
        XCTAssertEqual(object["deviceName"] as? String, "Mac")
        XCTAssertEqual((object["providers"] as? [Any])?.count, 0)
    }
}

final class TeamInviteLinkTests: XCTestCase {
    func testReadsAppAndWebInviteLinksAndBareCodes() {
        XCTAssertEqual(TeamInviteLink.code(from: URL(string: "godusage://join/AbC_123-xyz0")!), "AbC_123-xyz0")
        XCTAssertEqual(TeamInviteLink.code(from: URL(string: "https://api.example/join/AbC_123-xyz0")!), "AbC_123-xyz0")
        XCTAssertEqual(TeamInviteLink.code(fromText: "  AbC_123-xyz0\n"), "AbC_123-xyz0")
        XCTAssertEqual(TeamInviteLink.code(fromText: "https://api.example/join/AbC_123-xyz0"), "AbC_123-xyz0")
    }

    func testRejectsAnythingElse() {
        XCTAssertNil(TeamInviteLink.code(from: URL(string: "godusage://settings/AbC_123-xyz0")!))
        XCTAssertNil(TeamInviteLink.code(from: URL(string: "godusage://join/short")!))
        XCTAssertNil(TeamInviteLink.code(from: URL(string: "https://api.example/t/AbC_123-xyz0")!))
        XCTAssertNil(TeamInviteLink.code(from: URL(string: "ftp://api.example/join/AbC_123-xyz0")!))
        XCTAssertNil(TeamInviteLink.code(fromText: "not an invite"))
        XCTAssertNil(TeamInviteLink.code(fromText: "AbC_123-xyz0/../x"))
    }
}

final class TeamsAPIClientTests: XCTestCase {
    func testDevBuildsTalkToTheDevBackend() {
        let defaults = UserDefaults(suiteName: "TeamsAPIClientTests-\(UUID().uuidString)")!
        XCTAssertEqual(TeamsAPIClient.defaultBaseURL(bundleIdentifier: "com.montinovo.godusage.dev", defaults: defaults), TeamsAPIClient.developmentBaseURL)
        XCTAssertEqual(TeamsAPIClient.defaultBaseURL(bundleIdentifier: "com.montinovo.godusage", defaults: defaults), TeamsAPIClient.productionBaseURL)
        defaults.set("http://127.0.0.1:8787", forKey: TeamsAPIClient.baseURLOverrideKey)
        XCTAssertEqual(TeamsAPIClient.defaultBaseURL(bundleIdentifier: "com.montinovo.godusage", defaults: defaults), URL(string: "http://127.0.0.1:8787"))
    }

    func testSendsTheSessionAndDecodesTeams() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"teams":[{"id":"t1","name":"Crew","role":"owner","memberCount":2}]}"#.utf8)
        ))
        let client = TeamsAPIClient(baseURL: URL(string: "https://api.example")!, http: http)
        let teams = try await client.teams(token: "session-token")
        XCTAssertEqual(teams, [TeamSummary(id: "t1", name: "Crew", role: .owner, memberCount: 2)])
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://api.example/v1/teams")
        XCTAssertEqual(http.requests.first?.headers["authorization"], "Bearer session-token")
    }

    func testMapsServerErrorsToFriendlyMessages() async {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 409,
            headers: [:],
            body: Data(#"{"error":{"code":"conflict","message":"This team is full (50 members)."}}"#.utf8)
        ))
        let client = TeamsAPIClient(baseURL: URL(string: "https://api.example")!, http: http)
        do {
            _ = try await client.acceptInvite(token: "t", code: "AbC_123-xyz0")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TeamsAPIError, TeamsAPIError(kind: .conflict, message: "This team is full (50 members)."))
        }

        http.response = HTTPResponse(statusCode: 502, headers: [:], body: Data("<html>".utf8))
        do {
            _ = try await client.me(token: "t")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? TeamsAPIError)?.kind, .server)
            XCTAssertEqual(error.localizedDescription, "The teams server had a problem (HTTP 502). Try again later.")
        }
    }

    func testDeletingADeviceThatNeverUploadedSucceeds() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 404, headers: [:], body: Data()))
        let client = TeamsAPIClient(baseURL: URL(string: "https://api.example")!, http: http)
        try await client.deleteDevice(token: "t", deviceID: "device-1234")
        XCTAssertEqual(http.requests.first?.method, "DELETE")
    }
}
