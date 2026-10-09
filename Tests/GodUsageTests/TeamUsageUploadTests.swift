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

    private func body(_ providers: [TeamUsageUpload.Provider]) -> TeamUsageUpload {
        TeamUsageUpload(deviceName: "MacBook", appVersion: "1.0.9", windowStart: "2026-10-04", providers: providers)
    }

    private func day(_ date: String, _ tokens: Int) -> TeamUsageUpload.Day {
        .init(date: date, tokens: tokens, costUSD: Double(tokens), models: [.init(model: "m", tokens: tokens, costUSD: Double(tokens))])
    }

    func testAPartialUploadCarriesOnlyTheChangedProviderDays() throws {
        let previous = body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-04", 1), day("2026-10-05", 2)]),
            .init(provider: "codex", scope: "device", days: [day("2026-10-05", 3)]),
        ])
        let current = body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-04", 1), day("2026-10-05", 5)]),
            .init(provider: "codex", scope: "device", days: [day("2026-10-05", 3)]),
            .init(provider: "grok", scope: "device", days: [day("2026-10-05", 1)]),
        ])
        let partial = try XCTUnwrap(TeamUsageUpload.partial(from: previous, to: current))
        XCTAssertEqual(partial.partial, true)
        XCTAssertNil(partial.windowStart)
        XCTAssertEqual(partial.providers.map(\.provider), ["claude", "grok"])
        XCTAssertEqual(partial.providers.first?.days.map(\.date), ["2026-10-05"])

        let json = String(decoding: try JSONEncoder().encode(partial), as: UTF8.self)
        XCTAssertTrue(json.contains(#""partial":true"#))
        XCTAssertFalse(json.contains("windowStart"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(current), as: UTF8.self).contains("partial"))
    }

    func testAFullUploadIsNeededWhenUsageDisappears() {
        let previous = body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-04", 1), day("2026-10-05", 2)]),
            .init(provider: "codex", scope: "device", days: [day("2026-10-05", 3)]),
        ])
        // Codex was turned off.
        XCTAssertNil(TeamUsageUpload.partial(from: previous, to: body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-04", 1), day("2026-10-05", 2)]),
        ])))
        // A day of Claude is gone.
        XCTAssertNil(TeamUsageUpload.partial(from: previous, to: body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-05", 2)]),
            .init(provider: "codex", scope: "device", days: [day("2026-10-05", 3)]),
        ])))
        // Codex moved to account scope.
        XCTAssertNil(TeamUsageUpload.partial(from: previous, to: body([
            .init(provider: "claude", scope: "device", days: [day("2026-10-04", 1), day("2026-10-05", 2)]),
            .init(provider: "codex", scope: "account", days: [day("2026-10-05", 3)]),
        ])))
    }

    func testADayLeavingTheWindowStillAllowsAPartialUpload() throws {
        let previous = TeamUsageUpload(deviceName: "MacBook", windowStart: "2026-10-03", providers: [
            .init(provider: "claude", scope: "device", days: [day("2026-10-03", 1), day("2026-10-04", 2)]),
        ])
        let current = body([.init(provider: "claude", scope: "device", days: [day("2026-10-04", 2), day("2026-10-05", 4)])])
        let partial = try XCTUnwrap(TeamUsageUpload.partial(from: previous, to: current))
        XCTAssertEqual(partial.providers.first?.days.map(\.date), ["2026-10-05"])
    }

    func testAccountWideSourcesAreMarkedAccountScope() {
        let upload = TeamUsageUpload.make(
            sources: [TeamHistorySource(cardID: "cursor", scope: .accountWide, history: history([("2026-10-05", 9, 2)]))],
            deviceName: "MacBook",
            dayKeys: window
        )
        XCTAssertEqual(upload.providers.map(\.scope), ["account"])
    }

    func testSendsTheAccountFingerprintOnlyForAccountScope() throws {
        let key = TeamAccountKey.make(provider: "cursor", accountID: "user_01ABC")
        XCTAssertEqual(key.count, 64)
        XCTAssertEqual(key, TeamAccountKey.make(provider: "cursor", accountID: "user_01ABC"))
        XCTAssertNotEqual(key, TeamAccountKey.make(provider: "cursor", accountID: "user_02XYZ"))

        var cursor = history([("2026-10-05", 9, 2)])
        cursor.accountKey = key
        var local = history([("2026-10-05", 5, 1)])
        local.accountKey = "ignored"
        let upload = TeamUsageUpload.make(
            sources: [
                TeamHistorySource(cardID: "cursor", scope: .accountWide, history: cursor),
                TeamHistorySource(cardID: "claude", scope: .machineLocal, history: local),
            ],
            deviceName: "MacBook",
            dayKeys: window
        )
        XCTAssertEqual(upload.providers.map(\.account), [nil, key])
        let json = String(decoding: try JSONEncoder().encode(upload), as: UTF8.self)
        XCTAssertFalse(json.contains("user_01ABC"), "account ids must not leave the Mac")
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
        let upload = TeamUsageUpload.make(sources: [], deviceName: "Mac", dayKeys: window, appVersion: "1.0.8")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "godusage.team-usage.v1")
        XCTAssertEqual(object["deviceName"] as? String, "Mac")
        XCTAssertEqual(object["appVersion"] as? String, "1.0.8")
        // The window's first day, so the server keeps this Mac's older history.
        XCTAssertEqual(object["windowStart"] as? String, "2026-10-04")
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

@MainActor
final class AppleWebSignInTests: XCTestCase {
    /// Safari hands `<scheme>://auth` to the app's URL handler, which resumes the pending attempt.
    func testSafarisReturnLinkFinishesThePendingSignIn() async throws {
        var opened: URL?
        let signIn = AppleWebSignIn(baseURL: URL(string: "https://api.example")!, scheme: "godusage-dev") { opened = $0 }
        let attempt = Task { try await signIn.signIn() }
        while opened == nil { await Task.yield() }
        let start = try XCTUnwrap(opened)
        let items = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = try XCTUnwrap(items.first { $0.name == "state" }?.value)
        XCTAssertEqual(items.first { $0.name == "scheme" }?.value, "godusage-dev")

        // A link for another attempt is dropped; the right one finishes this one.
        XCTAssertTrue(AppleWebSignIn.receive(URL(string: "godusage-dev://auth?state=someone-else&code=x")!))
        XCTAssertFalse(AppleWebSignIn.receive(URL(string: "godusage-dev://join/abcdefgh12")!))
        XCTAssertTrue(AppleWebSignIn.receive(URL(string: "godusage-dev://auth?state=\(state)&code=c1")!))
        let result = try await attempt.value
        XCTAssertEqual(result.code, "c1")
        XCTAssertEqual(AppleWebSignIn.codeChallenge(for: result.codeVerifier), items.first { $0.name == "code_challenge" }?.value)
    }

    /// Starting again (the first Safari tab was closed) cancels the old attempt instead of refusing.
    func testANewSignInReplacesAnAbandonedOne() async throws {
        var opened: [URL] = []
        let signIn = AppleWebSignIn(baseURL: URL(string: "https://api.example")!, scheme: "godusage") { opened.append($0) }
        let first = Task { try await signIn.signIn() }
        while opened.isEmpty { await Task.yield() }
        let second = Task { try await signIn.signIn() }
        do {
            _ = try await first.value
            XCTFail("expected the first attempt to be cancelled")
        } catch {
            XCTAssertEqual(error as? AppleSignInError, .cancelled)
        }
        while opened.count < 2 { await Task.yield() }
        let state = try XCTUnwrap(URLComponents(url: opened[1], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        AppleWebSignIn.receive(URL(string: "godusage://auth?state=\(state)&code=c2")!)
        let secondCode = try await second.value.code
        XCTAssertEqual(secondCode, "c2")
    }

    func testFailsLoudlyWhenSafariCannotOpen() async {
        let signIn = AppleWebSignIn(baseURL: URL(string: "https://api.example")!, scheme: "godusage") { _ in
            throw AppleSignInError.failed("Safari isn't available on this Mac.")
        }
        do {
            _ = try await signIn.signIn()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AppleSignInError, .failed("Safari isn't available on this Mac."))
        }
    }

    func testEachChannelHasItsOwnScheme() {
        XCTAssertEqual(AppChannel.urlScheme(bundleIdentifier: "com.montinovo.godusage"), "godusage")
        XCTAssertEqual(AppChannel.urlScheme(bundleIdentifier: "com.montinovo.godusage.dev"), "godusage-dev")
    }

    /// base64url(SHA-256(verifier)), the S256 method the backend checks. Expected value from
    /// `printf %s <verifier> | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d =`.
    func testCodeChallengeIsBase64URLSHA256() {
        XCTAssertEqual(
            AppleWebSignIn.codeChallenge(for: "dBjftJeZ4CVP-mJ92K9KyJ5Uq8iFMRtOXsWoVhJIjKs"),
            "9p6i4Y_OvBa4C4GaHwICDKKq-VL3mq54gdaVJT1zpFI"
        )
    }

    func testStartURLCarriesTheStateAndChallenge() throws {
        let url = try XCTUnwrap(AppleWebSignIn.startURL(baseURL: URL(string: "https://api.example")!, state: "s1", codeVerifier: "v1", scheme: "godusage"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path(), "/v1/auth/apple/start")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "s1")
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, AppleWebSignIn.codeChallenge(for: "v1"))
    }

    func testReadsTheCodeOnlyForThisAttempt() throws {
        let ok = try AppleWebSignIn.result(from: URL(string: "godusage://auth?state=s1&code=c1")!, expectedState: "s1", codeVerifier: "v1", scheme: "godusage")
        XCTAssertEqual(ok, AppleSignInResult(code: "c1", codeVerifier: "v1"))

        XCTAssertThrowsError(try AppleWebSignIn.result(from: URL(string: "godusage://auth?state=other&code=c1")!, expectedState: "s1", codeVerifier: "v1", scheme: "godusage"))
        XCTAssertThrowsError(try AppleWebSignIn.result(from: URL(string: "godusage://join/abc?state=s1&code=c1")!, expectedState: "s1", codeVerifier: "v1", scheme: "godusage"))
        XCTAssertThrowsError(try AppleWebSignIn.result(from: URL(string: "godusage://auth?state=s1")!, expectedState: "s1", codeVerifier: "v1", scheme: "godusage"))
    }

    func testMapsServerErrors() {
        XCTAssertThrowsError(try AppleWebSignIn.result(from: URL(string: "godusage://auth?state=s1&error=cancelled")!, expectedState: "s1", codeVerifier: "v", scheme: "godusage")) {
            XCTAssertEqual($0 as? AppleSignInError, .cancelled)
        }
        XCTAssertThrowsError(try AppleWebSignIn.result(from: URL(string: "godusage://auth?state=s1&error=invalid_token")!, expectedState: "s1", codeVerifier: "v", scheme: "godusage")) {
            XCTAssertEqual($0 as? AppleSignInError, .failed("Apple's response couldn't be verified. Try again."))
        }
    }
}
