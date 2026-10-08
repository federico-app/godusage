import XCTest
@testable import GodUsage

final class TeamMemberNotesTests: XCTestCase {
    private func member(_ id: String, version: String?) -> TeamStats.Member {
        TeamStats.Member(userID: id, displayName: id, rank: 1, tokens: 0, costUSD: 0, providers: [], previous: nil, lastSyncAt: nil, appVersion: version)
    }

    func testNewestVersionComparesNumbersNotText() {
        let members = [member("a", version: "1.0.9"), member("b", version: "1.0.10"), member("c", version: nil)]
        XCTAssertEqual(TeamsFormat.newestVersion(members), "1.0.10")
        XCTAssertTrue(TeamsFormat.isOutdated("1.0.9", newest: "1.0.10"))
        XCTAssertFalse(TeamsFormat.isOutdated("1.0.10", newest: "1.0.10"))
    }

    func testDevSuffixAndUnknownVersionsAreNeverOutdatedByThemselves() {
        XCTAssertFalse(TeamsFormat.isOutdated("0.8.16-dev.642", newest: "0.8.16"))
        XCTAssertTrue(TeamsFormat.isOutdated("0.8.15-dev.600", newest: "0.8.16"))
        XCTAssertFalse(TeamsFormat.isOutdated(nil, newest: "1.0.9"))
        XCTAssertFalse(TeamsFormat.isOutdated("1.0.9", newest: nil))
    }

    func testDecodesMomentumAndReactionGivers() throws {
        let momentum = try JSONDecoder().decode(
            TeamMomentum.self,
            from: Data(#"{"lastHourUSD":12.4,"level":2,"reasons":["fast","top"],"typicalHourUSD":null}"#.utf8)
        )
        XCTAssertEqual(momentum, TeamMomentum(lastHourUSD: 12.4, level: 2, reasons: ["fast", "top"], typicalHourUSD: nil))
        let reactions = try JSONDecoder().decode(
            MemberReactions.self,
            from: Data(#"{"fire":1,"clap":0,"clown":0,"mine":[],"from":{"fire":["u2"],"clap":[],"clown":[]}}"#.utf8)
        )
        XCTAssertEqual(reactions.from?["fire"], ["u2"])
        // Older servers send neither.
        let old = try JSONDecoder().decode(MemberReactions.self, from: Data(#"{"fire":0,"clap":0,"clown":0,"mine":[]}"#.utf8))
        XCTAssertNil(old.from)
    }
}
