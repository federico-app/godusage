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

    func testKeepsRankOrderAndPicksARowStylePerMember() {
        let members = [member("a", rank: 1), member("b", rank: 2), member("c", rank: 3), member("d", rank: 4)]
        let layout = TeamLeaderboardLayout(
            members: members,
            momentum: ["c": momentum(level: 1), "a": momentum(level: 3), "b": momentum(level: 0)]
        )
        // #2 stays above #3 even though only #3 spent in the last hour.
        XCTAssertEqual(layout.rows.map(\.member.userID), ["a", "b", "c", "d"])
        XCTAssertEqual(layout.rows.map(\.style), [.full, .compact, .full, .compact])
        XCTAssertEqual(layout.activeCount, 2)
    }

    func testRowStyleFollowsLastHourSpend() {
        XCTAssertEqual(TeamLeaderboardLayout.rowStyle(nil), .compact)
        XCTAssertEqual(TeamLeaderboardLayout.rowStyle(TeamMomentum(lastHourUSD: 0, level: 0)), .compact)
        // A few dollars an hour is below the momentum threshold but still a full row.
        XCTAssertEqual(TeamLeaderboardLayout.rowStyle(TeamMomentum(lastHourUSD: 3, level: 0)), .full)
        XCTAssertEqual(TeamLeaderboardLayout.rowStyle(TeamMomentum(lastHourUSD: 0.01, level: 0)), .full)
        XCTAssertEqual(TeamLeaderboardLayout.rowStyle(TeamMomentum(lastHourUSD: 0, level: 2)), .full)
    }

    func testNobodySpendingKeepsEveryFullRowAndNoSummary() {
        let members = [member("a", rank: 1), member("b", rank: 2)]
        let layout = TeamLeaderboardLayout(members: members, momentum: ["a": momentum(level: 0)])
        XCTAssertEqual(layout.rows.map(\.member.userID), ["a", "b"])
        XCTAssertEqual(layout.rows.map(\.style), [.full, .full])
        XCTAssertEqual(layout.activeCount, 0)
        XCTAssertNil(TeamLeaderboardLayout.activeSummary(activeCount: layout.activeCount))
    }

    func testTopNCountsMembersInRankOrder() {
        let members = (1...6).map { member("m\($0)", rank: $0) }
        // Only the bottom two are spending: they don't jump the collapse.
        let layout = TeamLeaderboardLayout(members: members, momentum: ["m5": momentum(level: 1), "m6": momentum(level: 2)])
        XCTAssertEqual(layout.visibleRows(limit: 3).map(\.member.userID), ["m1", "m2", "m3"])
        XCTAssertEqual(layout.visibleRows(limit: 10).map(\.member.userID), members.map(\.userID))
        XCTAssertTrue(layout.visibleRows(limit: 0).isEmpty)
    }

    func testTiesKeepTheirLabelsWhateverTheRowStyle() {
        let members = [member("a", rank: 1), member("b", rank: 2), member("c", rank: 2), member("d", rank: 4)]
        let layout = TeamLeaderboardLayout(members: members, momentum: ["c": momentum(level: 1)])
        XCTAssertEqual(layout.rows.map(\.member.userID), ["a", "b", "c", "d"])
        XCTAssertEqual(layout.rows.map(\.style), [.compact, .compact, .full, .compact])
        XCTAssertEqual(layout.rows.map { layout.rankLabel($0.member) }, ["1", "2=", "2=", "4"])
    }

    func testActiveSummary() {
        XCTAssertEqual(TeamLeaderboardLayout.activeSummary(activeCount: 4), "4 active now")
        XCTAssertEqual(TeamLeaderboardLayout.activeSummary(activeCount: 1), "1 active now")
        XCTAssertNil(TeamLeaderboardLayout.activeSummary(activeCount: 0))
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
