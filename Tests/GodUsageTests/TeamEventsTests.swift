import XCTest
@testable import GodUsage

final class TeamEventsTests: XCTestCase {
    private func member(_ id: String, _ name: String, rank: Int, cost: Double, previousRank: Int? = nil) -> TeamStats.Member {
        TeamStats.Member(
            userID: id, displayName: name, rank: rank, tokens: Int(cost * 1000), costUSD: cost, providers: [],
            previous: previousRank.map { TeamStats.Previous(rank: $0, tokens: 1, costUSD: 1) }
        )
    }

    private func stats(_ members: [TeamStats.Member], models: [TeamStats.Model] = []) -> TeamStats {
        TeamStats(
            range: .init(name: .week, from: "2026-09-29", to: "2026-10-05"),
            sort: .cost,
            totals: UsageTotals(tokens: 0, costUSD: 0),
            members: members,
            providers: [],
            models: models,
            daily: []
        )
    }

    func testTheFirstCheckOnlyRecordsTheBaseline() {
        let board = stats([member("ada", "Ada", rank: 1, cost: 9), member("me", "Me", rank: 2, cost: 5)])
        XCTAssertTrue(TeamEvents.newOvertakers(previousAbove: nil, stats: board, me: "me").isEmpty)
        XCTAssertEqual(TeamEvents.membersAbove("me", in: board), ["ada"])
    }

    func testReportsOnlyNewOvertakers() {
        let board = stats([
            member("ada", "Ada", rank: 1, cost: 9),
            member("bea", "Bea", rank: 2, cost: 7),
            member("me", "Me", rank: 3, cost: 5),
        ])
        let passed = TeamEvents.newOvertakers(previousAbove: ["ada"], stats: board, me: "me")
        XCTAssertEqual(passed.map(\.displayName), ["Bea"])
        XCTAssertEqual(TeamEvents.overtakeMessage(passed, team: "Crew").title, "Bea Passed You")
    }

    func testTiesAndIdleMembersDoNotCountAsOvertakes() {
        let tied = stats([member("ada", "Ada", rank: 1, cost: 5), member("me", "Me", rank: 1, cost: 5)])
        XCTAssertTrue(TeamEvents.newOvertakers(previousAbove: [], stats: tied, me: "me").isEmpty)
    }

    func testNamesSeveralOvertakersTogether() {
        let message = TeamEvents.overtakeMessage(
            [member("a", "Ada", rank: 1, cost: 1), member("b", "Bea", rank: 2, cost: 1), member("c", "Cy", rank: 3, cost: 1)],
            team: "Crew"
        )
        XCTAssertEqual(message.title, "Ada, Bea and Cy Passed You")
    }

    func testWeeklyRecapIsDueFromMondayAtNine() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let date = { (string: String) in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
            return formatter.date(from: string)!
        }
        // Monday 5 October 2026, 08:59 — not yet.
        XCTAssertNil(TeamEvents.weeklyRecapDue(now: date("2026-10-05T08:59:00"), lastSentWeek: nil, calendar: calendar))
        // 09:00 — due, summarizing the week that ended Sunday 4 October.
        let due = try XCTUnwrap(TeamEvents.weeklyRecapDue(now: date("2026-10-05T09:00:00"), lastSentWeek: nil, calendar: calendar))
        XCTAssertEqual(due.week, "2026-W41")
        XCTAssertEqual(due.endDay, "2026-10-04")
        // Later that week it is still due until sent, then not again.
        XCTAssertNotNil(TeamEvents.weeklyRecapDue(now: date("2026-10-08T15:00:00"), lastSentWeek: "2026-W40", calendar: calendar))
        XCTAssertNil(TeamEvents.weeklyRecapDue(now: date("2026-10-08T15:00:00"), lastSentWeek: "2026-W41", calendar: calendar))
    }

    func testWeeklyRecapMessage() throws {
        let model = TeamStats.Model(
            model: "claude-opus-4-1", provider: "claude", tokens: 10, costUSD: 4,
            members: [TeamStats.MemberTotals(userID: "me", tokens: 10, costUSD: 4)]
        )
        let board = stats(
            [member("ada", "Ada", rank: 1, cost: 9), member("me", "Me", rank: 2, cost: 5, previousRank: 3)],
            models: [model]
        )
        let message = try XCTUnwrap(TeamEvents.weeklyRecapMessage(stats: board, team: "Crew", me: "me"))
        XCTAssertEqual(message.title, "Last Week in Crew")
        XCTAssertEqual(message.body, "You were #2 of 2 with $5.00, up 1. Ada led with $9.00. Your top model: claude-opus-4-1.")
    }

    @MainActor
    func testWrappedCardRenders() throws {
        let board = stats([member("me", "Me", rank: 1, cost: 5)])
        let card = TeamWrappedCard(teamName: "Crew", periodTitle: "Last 30 Days", stats: board, me: board.members.first, providerName: { $0 })
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        XCTAssertEqual(image.size.width, 380, accuracy: 1)
    }
}
