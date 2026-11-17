import XCTest
@testable import GodUsage

final class TeamLeaderboardLayoutTests: XCTestCase {
    private func member(
        _ id: String, rank: Int, cost: Double = 0, tokens: Int = 0, providers: [TeamStats.ProviderTotals] = []
    ) -> TeamStats.Member {
        TeamStats.Member(
            userID: id, displayName: id, rank: rank, tokens: tokens, costUSD: cost, providers: providers,
            previous: nil, lastSyncAt: nil, appVersion: nil
        )
    }

    private func momentum(level: Int) -> TeamMomentum {
        TeamMomentum(lastHourUSD: Double(level) * 5, level: level)
    }

    func testTiedRanksGetAnEqualsSign() {
        let members = [member("a", rank: 1), member("b", rank: 2), member("c", rank: 3), member("d", rank: 3), member("e", rank: 4)]
        let labels = TeamLeaderboardLayout.rankLabels(members)
        XCTAssertEqual(labels["a"], "1")
        XCTAssertEqual(labels["b"], "2")
        XCTAssertEqual(labels["c"], "3=")
        XCTAssertEqual(labels["d"], "3=")
        XCTAssertEqual(labels["e"], "4")
    }

    func testTieAtTheEndAndSingleMember() {
        let members = [member("a", rank: 1), member("b", rank: 2), member("c", rank: 2)]
        XCTAssertEqual(TeamLeaderboardLayout.rankLabels(members), ["a": "1", "b": "2=", "c": "2="])
        XCTAssertEqual(TeamLeaderboardLayout.rankLabels([member("a", rank: 1)]), ["a": "1"])
    }

    func testSplitsActiveAndIdleKeepingRankOrder() {
        let members = [member("a", rank: 1), member("b", rank: 2), member("c", rank: 3), member("d", rank: 4)]
        let layout = TeamLeaderboardLayout(
            members: members,
            momentum: ["c": momentum(level: 1), "a": momentum(level: 3), "b": momentum(level: 0)]
        )
        XCTAssertEqual(layout.active.map(\.userID), ["a", "c"])
        XCTAssertEqual(layout.idle.map(\.userID), ["b", "d"])
        XCTAssertEqual(layout.activeCount, 2)
    }

    func testNoSplitWhenNobodyIsActive() {
        let members = [member("a", rank: 1), member("b", rank: 2)]
        let layout = TeamLeaderboardLayout(members: members, momentum: ["a": momentum(level: 0)])
        XCTAssertEqual(layout.active.map(\.userID), ["a", "b"])
        XCTAssertTrue(layout.idle.isEmpty)
        XCTAssertEqual(layout.activeCount, 0)
    }

    func testHeaderDetail() {
        XCTAssertEqual(TeamLeaderboardLayout.headerDetail(metric: .spend, activeCount: 4), "team · 4 active")
        XCTAssertEqual(TeamLeaderboardLayout.headerDetail(metric: .spend, activeCount: 0), "team")
        XCTAssertEqual(TeamLeaderboardLayout.headerDetail(metric: .tokens, activeCount: 1), "team tokens · 1 active")
    }

    func testLegendListsOnlyProvidersOnTheBarsLargestFirst() {
        let members = [
            member("a", rank: 1, cost: 30, tokens: 100, providers: [
                .init(provider: "claude", tokens: 90, costUSD: 25),
                .init(provider: "codex", tokens: 10, costUSD: 5),
                .init(provider: "grok", tokens: 0, costUSD: 0),
            ]),
            member("b", rank: 2, cost: 10, tokens: 50, providers: [.init(provider: "codex", tokens: 50, costUSD: 10)]),
        ]
        let shared = [TeamStats.SharedAccount(provider: "cursor", tokens: 5, costUSD: 2, members: ["a", "b"])]
        XCTAssertEqual(
            TeamLeaderboardLayout.legendProviders(members: members, shared: shared, metric: .spend),
            ["claude", "codex", "cursor"]
        )
        // Tokens rank the legend by tokens instead.
        XCTAssertEqual(
            TeamLeaderboardLayout.legendProviders(members: members, shared: [], metric: .tokens),
            ["claude", "codex"]
        )
        XCTAssertTrue(TeamLeaderboardLayout.legendProviders(members: [], shared: [], metric: .spend).isEmpty)
    }

    func testSyncAgeIsShort() {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        XCTAssertEqual(TeamsFormat.syncAge("2026-10-05T11:59:30Z", now: now), .init(text: "just now", stale: false))
        XCTAssertEqual(TeamsFormat.syncAge("2026-10-05T11:55:00.000Z", now: now), .init(text: "5m ago", stale: false))
        XCTAssertEqual(TeamsFormat.syncAge("2026-10-04T13:00:00Z", now: now), .init(text: "23h ago", stale: false))
        XCTAssertEqual(TeamsFormat.syncAge("2026-10-01T12:00:00Z", now: now), .init(text: "4d ago", stale: true))
        XCTAssertNil(TeamsFormat.syncAge(nil, now: now))
    }
}
