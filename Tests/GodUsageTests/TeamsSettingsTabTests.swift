import XCTest
@testable import GodUsage

final class TeamsSettingsTabTests: XCTestCase {
    func testShowsTeamPagesOnlyWithATeamAndPlansOnlyToOwners() {
        XCTAssertEqual(TeamsSettingsTab.available(for: nil), [.you])
        let team = TeamSummary(id: "t", name: "DEV", role: .member, memberCount: 3)
        XCTAssertEqual(TeamsSettingsTab.available(for: team), [.members, .accounts, .you])
        var owned = team
        owned.role = .owner
        XCTAssertEqual(TeamsSettingsTab.available(for: owned), [.members, .accounts, .plans, .you])
    }
}
