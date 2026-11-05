import XCTest
@testable import GodUsage

/// Leaving an account out of a team: the upload sends it on its own with the teams it is left out of.
final class TeamAccountSharingTests: XCTestCase {
    /// Today, so the store's own upload (the last 30 days from now) keeps it.
    private let day = DailyUsageAccumulator.dayKey(from: Date())
    private var window: Set<String> { [day] }

    private func source(_ cardID: String, cost: Double, plan: String? = nil) -> TeamHistorySource {
        TeamHistorySource(
            cardID: cardID,
            scope: .machineLocal,
            history: ProviderUsageHistory(series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: Int(cost), costUSD: cost)])),
            plan: plan
        )
    }

    func testSplitsAnAccountLeftOutOfATeamAndFoldsTheRest() throws {
        let upload = TeamUsageUpload.make(
            sources: [
                source("claude", cost: 11, plan: "Max 5x"),
                source("claude@ab12cd34", cost: 30, plan: "Team"),
                source("claude@ffff0000", cost: 2),
                source("codex", cost: 4),
            ],
            deviceName: "MacBook",
            dayKeys: window,
            excludedCards: ["work-team": ["claude"]],
            accountKey: { "key-\($0.cardID)" }
        )

        XCTAssertEqual(upload.providers.map(\.entryKey), ["claude", "claude|key-claude", "codex"])
        let folded = try XCTUnwrap(upload.providers.first { $0.split == nil && $0.provider == "claude" })
        XCTAssertEqual(folded.days.first?.costUSD, 32)
        XCTAssertNil(folded.account)
        let split = try XCTUnwrap(upload.providers.first { $0.split == true })
        XCTAssertEqual(split.scope, "device")
        XCTAssertEqual(split.account, "key-claude")
        XCTAssertEqual(split.days.first?.costUSD, 11)
        XCTAssertEqual(upload.excludedAccounts, [.init(team: "work-team", provider: "claude", account: "key-claude")])
        // The plan the team pays for comes from an account it counts.
        XCTAssertEqual(upload.detectedPlans, [.init(provider: "claude", plan: "Team")])
    }

    func testWithoutExclusionsTheUploadIsUnchanged() {
        let sources = [source("claude", cost: 11), source("claude@ab12cd34", cost: 30)]
        let plain = TeamUsageUpload.make(sources: sources, deviceName: "MacBook", dayKeys: window)
        let empty = TeamUsageUpload.make(sources: sources, deviceName: "MacBook", dayKeys: window, excludedCards: [:])
        XCTAssertEqual(plain, empty)
        XCTAssertEqual(plain.providers.count, 1)
        XCTAssertNil(plain.providers.first?.split)
    }

    func testChangingWhichAccountsAreSplitNeedsAFullUpload() throws {
        let sources = [source("claude", cost: 11)]
        let folded = TeamUsageUpload.make(sources: sources, deviceName: "MacBook", dayKeys: window)
        let split = TeamUsageUpload.make(sources: sources, deviceName: "MacBook", dayKeys: window, excludedCards: ["t": ["claude"]])
        XCTAssertNil(TeamUsageUpload.partial(from: folded, to: split))
        XCTAssertNil(TeamUsageUpload.partial(from: split, to: folded))

        // An unchanged split account sends nothing in a partial upload.
        let again = try XCTUnwrap(TeamUsageUpload.partial(from: split, to: split))
        XCTAssertTrue(again.providers.isEmpty)
        XCTAssertEqual(again.excludedAccounts, split.excludedAccounts)
    }

    func testEncodesSplitEntriesAndExclusions() throws {
        let upload = TeamUsageUpload.make(
            sources: [source("claude", cost: 1)], deviceName: "MacBook", dayKeys: window,
            excludedCards: ["t": ["claude"]], accountKey: { _ in "abc" }
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any])
        let provider = try XCTUnwrap((json["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(provider["split"] as? Bool, true)
        XCTAssertEqual(provider["account"] as? String, "abc")
        XCTAssertNil(provider["entryKey"])
        XCTAssertEqual(json["excludedAccounts"] as? [[String: String]], [["team": "t", "provider": "claude", "account": "abc"]])
    }

    func testAClaudeAccountKeyMatchesItsQuotaWindowsKey() {
        let key = TeamsStore.accountKey(for: source("claude@ab12cd34", cost: 1), deviceID: "device-0001")
        XCTAssertEqual(key, TeamAccountKey.make(provider: "claude", accountID: "device-0001|claude@ab12cd34"))
    }

    @MainActor
    func testTheChoiceIsKeptPerTeamAndUploadsAtOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TeamAccountSharingTests-\(UUID().uuidString)"))
        let api = FakeTeamsAPI()
        let sessions = InMemoryTeamsSessionStore()
        sessions.saved = TeamsSession(token: "s", user: TeamsUser(id: "u1", displayName: "Fede"))
        api.teamsResult = [
            TeamSummary(id: "work", name: "Work", role: .member, memberCount: 2),
            TeamSummary(id: "friends", name: "Friends", role: .member, memberCount: 2),
        ]
        let sources = [source("claude", cost: 11), source("claude@ab12cd34", cost: 30)]
        let make = {
            TeamsStore(
                api: api, sessionStore: sessions, signInProvider: FakeAppleSignIn(), historySources: { sources },
                deviceID: { "device-0001" }, deviceName: "Mac", uploadDebounce: .zero, defaults: defaults
            )
        }
        let store = make()
        await store.refresh()
        XCTAssertEqual(store.shareableCardIDs(), ["claude", "claude@ab12cd34"])

        store.setCardCounted(false, cardID: "claude", in: "work")
        XCTAssertFalse(store.isCardCounted("claude", in: "work"))
        XCTAssertTrue(store.isCardCounted("claude", in: "friends"))
        let deadline = Date().addingTimeInterval(2)
        while api.uploads.last?.upload.excludedAccounts.isEmpty ?? true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = try XCTUnwrap(api.uploads.last?.upload)
        XCTAssertEqual(sent.excludedAccounts.map(\.team), ["work"])
        XCTAssertEqual(sent.providers.map(\.entryKey).count, 2)

        // Kept on this Mac across launches.
        XCTAssertFalse(make().isCardCounted("claude", in: "work"))
        store.setCardCounted(true, cardID: "claude", in: "work")
        XCTAssertTrue(make().isCardCounted("claude", in: "work"))
    }
}
