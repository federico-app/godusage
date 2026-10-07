import XCTest
@testable import GodUsage

final class TeamDashboardPreferencesTests: XCTestCase {
    func testCollapsedRankingShowsTheTopMembersOnly() {
        XCTAssertEqual(TeamMembersShown.default, .two)
        XCTAssertEqual(TeamMembersShown.two.visibleCount(of: 6), 2)
        XCTAssertEqual(TeamMembersShown.five.visibleCount(of: 6), 5)
        XCTAssertEqual(TeamMembersShown.three.visibleCount(of: 2), 2)
        XCTAssertEqual(TeamMembersShown.all.visibleCount(of: 6), 6)
    }
}
