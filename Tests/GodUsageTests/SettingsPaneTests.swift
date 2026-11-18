import XCTest
@testable import GodUsage

/// The Settings window's pane identity: raw values are persisted (last-selected pane, per-pane
/// height keys) and double as the toolbar item identifiers, so they must stay stable, and every
/// pane must round-trip through its raw value.
final class SettingsPaneTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.rawValue),
            ["general", "appearance", "notifications", "teams", "advanced"]
        )
    }

    func testRawValueRoundTrips() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane(rawValue: pane.rawValue), pane)
        }
    }

    func testEveryPaneHasTitleAndSymbol() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty)
            XCTAssertFalse(pane.systemSymbol.isEmpty)
        }
    }
}

/// Regression: the window opened at the wrong height because the pane's first layout, at the
/// near-zero width the hosting view has while the window is built, reported a height several times
/// the real one, and that height was applied and remembered.
final class SettingsPaneMeasurementTests: XCTestCase {
    func testIgnoresTheNearZeroWidthFirstLayout() {
        XCTAssertFalse(SettingsPaneHost.isSettledLayout(width: 1))
        XCTAssertFalse(SettingsPaneHost.isSettledLayout(width: 0))
    }

    func testAcceptsEveryWidthTheWindowCanHave() {
        XCTAssertTrue(SettingsPaneHost.isSettledLayout(width: SettingsPaneHost.minimumContentWidth))
        XCTAssertTrue(SettingsPaneHost.isSettledLayout(width: SettingsPaneHost.defaultContentWidth))
        XCTAssertTrue(SettingsPaneHost.isSettledLayout(width: SettingsPaneHost.maximumContentWidth))
    }
}
