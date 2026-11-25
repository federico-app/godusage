import XCTest
@testable import GodUsage

/// The local Usage Trend and spend tiles come only from conversation databases on this Mac, so a
/// login problem with the quota sources must not hide them (regression: they vanished on every
/// error and connect-prompt refresh).
@MainActor
final class AntigravityLocalUsageProviderTests: XCTestCase {
    private let tileLabels = ["Today", "Last 7 Days", "Last 30 Days", "Usage Trend"]

    func testSignedOutRefreshStillServesLocalTilesUnderTheNotice() async throws {
        let provider = try makeProvider(keychain: FakeKeychain(nil), cloudStatus: 500)
        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertEqual(snapshot.warning, AntigravityError.notSignedIn.localizedDescription)
        XCTAssertEqual(snapshot.warningIsConnectPrompt, false)
        XCTAssertEqual(snapshot.loginRequired, true)
        XCTAssertEqual(snapshot.lines.map(\.label), tileLabels)
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testConnectRequiredRefreshStillServesLocalTilesWithTheConnectPrompt() async throws {
        let provider = try makeProvider(keychain: DeferredAntigravityKeychain(), cloudStatus: 500)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.warning, AntigravityError.keychainConnectRequired.localizedDescription)
        XCTAssertEqual(snapshot.warningIsConnectPrompt, true)
        XCTAssertEqual(snapshot.lines.map(\.label), tileLabels)
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testWithoutLocalUsageTheConnectPromptAndErrorCardAreUnchanged() async {
        let routing = RoutingHTTPClient { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        func provider(_ keychain: KeychainReading) -> AntigravityProvider {
            AntigravityProvider(
                authStore: AntigravityAuthStore(keychain: keychain, files: FakeFiles()),
                usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
                discovery: LanguageServerDiscovery(processRunner: NoProcessRunner()),
                conversationScanner: .emptyForTesting
            )
        }
        let connect = await provider(DeferredAntigravityKeychain()).refresh()
        XCTAssertEqual(connect.lines.first?.label, MetricLine.connectBadgeLabel)
        let signedOut = await provider(FakeKeychain(nil)).refresh()
        XCTAssertTrue(signedOut.lines.contains { $0.isError })
    }

    func testTransientOutageStaysAnErrorCardSoTheLastGoodSnapshotIsKept() async throws {
        let inner = #"{"token":{"access_token":"ya29.kc","refresh_token":"1//r","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let provider = try makeProvider(keychain: FakeKeychain(wrapped), cloudStatus: 503)
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    // MARK: - Fixtures

    private func makeProvider(keychain: KeychainReading, cloudStatus: Int) throws -> AntigravityProvider {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("godusage-antigravity-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("conversation.db").path
        try Data("db".utf8).write(to: URL(fileURLWithPath: path))
        let sqlite = AntigravityFakeSQLite(results: [
            path: AntigravityFakeSQLite.json(
                generations: [(0, ProtoFixture.generation(
                    modelEnum: 1533, input: 1_000, output: 200, cacheRead: 5_000, steps: [1],
                    configName: "gemini-4-neon-medium"
                ))],
                steps: [(1, ProtoFixture.step(at: now.addingTimeInterval(-1)))]
            )
        ])
        let routing = RoutingHTTPClient { _ in HTTPResponse(statusCode: cloudStatus, headers: [:], body: Data()) }
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: keychain, files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner()),
            conversationScanner: AntigravityConversationScanner(sqlite: sqlite, conversationsDirectory: { directory }),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }
}

/// Present in Keychain, but the automatic path deferred the secret read: the connect-prompt shape.
private final class DeferredAntigravityKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func lastReadFailure(service: String, account: String) -> KeychainReadFailure? {
        .manualReadDeferred
    }
}
