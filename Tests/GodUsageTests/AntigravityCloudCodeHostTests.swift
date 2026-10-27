import XCTest
@testable import GodUsage

/// Covers which Cloud Code hosts answer the quota summary (production first, daily merged in when
/// production's answer is incomplete or fails) and the Antigravity-shaped `loadCodeAssist` request.
final class AntigravityCloudCodeHostTests: XCTestCase {
    private static let production = "cloudcode-pa.googleapis.com"
    private static let daily = "daily-cloudcode-pa.googleapis.com"

    /// Four shared quota windows plus Argon, as production returns them.
    private static let fullBody = """
    {"groups":[
      {"displayName":"Gemini 4 Argon","buckets":[
        {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.6}
      ]},
      {"displayName":"Claude and other models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1},
        {"bucketId":"3p-5h","window":"5h","remainingFraction":0.4}
      ]},
      {"displayName":"Gemini models","buckets":[
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.75},
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.9}
      ]}
    ]}
    """

    private static let claudeOnlyBody = """
    {"groups":[{"displayName":"Claude and GPT models","buckets":[
      {"bucketId":"3p-weekly","remainingFraction":0.8},
      {"bucketId":"3p-5h","remainingFraction":1}
    ]}]}
    """

    private static let allLabels = ["Session", "Weekly", "Argon Weekly", "Claude", "Claude Weekly"]

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = line else { return nil }
        return used
    }

    @MainActor
    private func makeProvider(_ routing: RoutingHTTPClient) -> AntigravityProvider {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing, clientVersion: { nil }),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner())
        )
    }

    /// Answers the quota summary per host; every other path is a 404.
    private func summaryRouting(
        _ answer: @escaping @Sendable (String?) async throws -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            guard request.url.path == AntigravityUsageClient.quotaSummaryPath else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return try await answer(request.url.host)
        }
    }

    private static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    private func summaryHosts(_ routing: RoutingHTTPClient) -> [String] {
        routing.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.compactMap { $0.url.host }
    }

    func testProductionIsAskedBeforeDaily() {
        XCTAssertEqual(AntigravityUsageClient.cloudCodeURLs.first, "https://\(Self.production)")
        XCTAssertEqual(AntigravityUsageClient.cloudCodeURLs.last, "https://\(Self.daily)")
    }

    /// Regression: on 2026-10-17 one Cloud Code host answered with only the Claude group while the
    /// other returned both, and taking the first 2xx host left Session/Weekly at "No data".
    @MainActor
    func testSummaryMergesBucketsAcrossHostsWhenOneOmitsAPool() async {
        let full = Self.fullBody, partial = Self.claudeOnlyBody
        let routing = summaryRouting { host in Self.ok(host == Self.production ? partial : full) }

        let snapshot = await makeProvider(routing).refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), Self.allLabels)
        // Claude buckets come from production (first wins); Gemini and Argon from the daily host.
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 0, 20])
        XCTAssertEqual(summaryHosts(routing), [Self.production, Self.daily])
    }

    @MainActor
    func testCompleteProductionSummaryDoesNotWaitForAStalledDailyHost() async {
        let full = Self.fullBody
        let routing = summaryRouting { host in
            if host == Self.daily { try await Task.sleep(for: .seconds(30)) }
            return Self.ok(full)
        }

        let start = Date()
        let snapshot = await makeProvider(routing).refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(snapshot.lines.map(\.label), Self.allLabels)
        XCTAssertEqual(summaryHosts(routing), [Self.production])
    }

    @MainActor
    func testSummaryFromDailySurvivesAuthFailureOnProduction() async {
        let full = Self.fullBody
        let routing = summaryRouting { host in
            host == Self.production ? HTTPResponse(statusCode: 403, headers: [:], body: Data()) : Self.ok(full)
        }

        let snapshot = await makeProvider(routing).refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), Self.allLabels)
    }

    @MainActor
    func testProduction503FallsBackToPartialDailySummary() async {
        let partial = Self.claudeOnlyBody
        let routing = summaryRouting { host in
            host == Self.production ? HTTPResponse(statusCode: 503, headers: [:], body: Data()) : Self.ok(partial)
        }

        let snapshot = await makeProvider(routing).refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Claude", "Claude Weekly"],
                       "Gemini and Argon rows stay absent when the fallback has no data for them")
        XCTAssertEqual(summaryHosts(routing), [Self.production, Self.daily])
        XCTAssertFalse(routing.requests.contains { $0.url.path == AntigravityUsageClient.fetchModelsPath })
    }

    @MainActor
    func testProductionTimeoutFallsBackToDailySummary() async {
        let full = Self.fullBody
        let routing = summaryRouting { host in
            if host == Self.production { throw URLError(.timedOut) }
            return Self.ok(full)
        }

        let snapshot = await makeProvider(routing).refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), Self.allLabels)
        XCTAssertEqual(snapshot.lines.map { used($0) }, [25, 10, 40, 60, 0])
    }

    // MARK: - loadCodeAssist client identity

    func testUserAgentUsesInstalledVersionOrFallsBack() {
        XCTAssertTrue(AntigravityClientVersion.userAgent(version: "2.23.1")
            .hasPrefix("antigravity/2.23.1 (aidev_client; os_type=darwin; arch="))
        let fallbackPrefix = "antigravity/\(AntigravityClientVersion.fallback) (aidev_client;"
        XCTAssertTrue(AntigravityClientVersion.userAgent(version: nil).hasPrefix(fallbackPrefix))
        // A malformed Info.plist value never reaches the header.
        for bad in ["", "  ", "2.23.1 (evil)", "v2", "2.23.1\r\nX-Injected: 1", "1.2.3.4.5"] {
            XCTAssertTrue(AntigravityClientVersion.userAgent(version: bad).hasPrefix(fallbackPrefix), bad)
        }
    }

    @MainActor
    func testLoadCodeAssistSendsClientMetadataAndFallbackUserAgent() async {
        let routing = RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"id":"g1-ultra-tier"}}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let client = AntigravityUsageClient(lsHTTP: routing, http: routing, clientVersion: { nil })

        guard case .ok(let data) = await client.loadCodeAssist(token: "t") else { return XCTFail("expected 2xx") }
        XCTAssertEqual(AntigravityUsageMapper.parseLoadCodeAssistPlan(data), "Ultra")
        let request = routing.requests.first
        XCTAssertEqual(request?.url.host, Self.production)
        XCTAssertEqual(request?.headers["User-Agent"], AntigravityClientVersion.userAgent(version: nil))
        let body = request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(body?["metadata"] as? [String: String], [
            "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"
        ])
    }
}
