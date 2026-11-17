import AppKit
import XCTest
@testable import GodUsage

/// The blue arrow that ends the menu-bar strip while the dashboard shows its "Update Available"
/// banner (`MenuBarUpdateIndicator`).
@MainActor
final class MenuBarUpdateIndicatorTests: XCTestCase {
    // MARK: Decision

    func testShowsWhileAnUpdateIsAvailable() {
        XCTAssertEqual(MenuBarUpdateIndicator.version(available: "1.9.1", concealUsage: false), "1.9.1")
    }

    func testHiddenWhenNoUpdateIsAvailable() {
        XCTAssertNil(MenuBarUpdateIndicator.version(available: nil, concealUsage: false))
        XCTAssertNil(MenuBarUpdateIndicator.version(available: "", concealUsage: false))
    }

    func testHiddenWhileScreenSharePrivacyConcealsTheStrip() {
        XCTAssertNil(MenuBarUpdateIndicator.version(available: "1.9.1", concealUsage: true))
        XCTAssertNil(MenuBarUpdateIndicator.version(available: nil, concealUsage: true))
    }

    // MARK: Accessibility and tooltip

    func testAccessibilityText() {
        XCTAssertEqual(MenuBarUpdateIndicator.text(version: "1.9.1"), "GodUsage 1.9.1 available")
    }

    func testItalianAccessibilityText() throws {
        let resources = Bundle.godUsageResources
        let italian = try XCTUnwrap(resources.url(forResource: "it", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let format = italian.localizedString(forKey: "GodUsage %@ available", value: nil, table: nil)
        XCTAssertEqual(String(format: format, "1.9.1"), "GodUsage 1.9.1 disponibile")
    }

    func testStripAccessibilityEndsWithTheUpdate() {
        var content = makeContent()
        content.updateVersion = "1.9.1"
        XCTAssertEqual(content.accessibilityText, "Claude Session 41%; GodUsage 1.9.1 available")
        XCTAssertEqual(
            MenuBarContent(groups: [], bars: [], updateVersion: "1.9.1").accessibilityText,
            "GodUsage 1.9.1 available"
        )
    }

    // MARK: Rendering

    func testArrowForcesTheColoredRenderInBothStyles() {
        var content = makeContent()
        XCTAssertFalse(content.needsColor(style: .text))
        XCTAssertFalse(content.needsColor(style: .bars))
        content.updateVersion = "1.9.1"
        XCTAssertTrue(content.needsColor(style: .text))
        XCTAssertTrue(content.needsColor(style: .bars))
    }

    func testUpdateVersionChangeIsNotRenderEquivalent() {
        var withUpdate = makeContent()
        withUpdate.updateVersion = "1.9.1"
        XCTAssertFalse(makeContent().isRenderEquivalent(to: withUpdate, style: .text))
        XCTAssertFalse(makeContent().isRenderEquivalent(to: withUpdate, style: .bars))
    }

    func testOnlyTheArrowStillRendersAStrip() throws {
        let content = MenuBarContent(groups: [], bars: [], updateVersion: "1.9.1")
        XCTAssertFalse(content.isEmpty)
        for style in [MenuBarStyle.text, .bars] {
            let presentation = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: style))
            XCTAssertFalse(presentation.image.isTemplate)
            XCTAssertEqual(presentation.toolTipRegions.map(\.displayName), ["GodUsage 1.9.1 available"])
        }
    }

    func testTextStripAddsATrailingArrowRegion() throws {
        var content = makeContent()
        content.updateVersion = "1.9.1"
        let presentation = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: .text))
        let regions = presentation.toolTipRegions
        XCTAssertEqual(regions.map(\.displayName), ["Claude", "GodUsage 1.9.1 available"])
        XCTAssertEqual(regions[0].rect.maxX, regions[1].rect.minX, accuracy: 0.001)
        XCTAssertEqual(regions[1].rect.maxX, presentation.image.size.width, accuracy: 0.001)
        XCTAssertGreaterThan(regions[1].rect.width, 0)
    }

    func testBarsStripLabelsOnlyTheArrow() throws {
        var content = makeContent()
        content.updateVersion = "1.9.1"
        let presentation = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: .bars))
        let region = try XCTUnwrap(presentation.toolTipRegions.first)
        XCTAssertEqual(presentation.toolTipRegions.count, 1)
        XCTAssertEqual(region.displayName, "GodUsage 1.9.1 available")
        XCTAssertEqual(region.rect.maxX, presentation.image.size.width, accuracy: 0.001)
        XCTAssertLessThan(region.rect.width, presentation.image.size.width)
    }

    private func makeContent() -> MenuBarContent {
        let session = MenuBarContent.Metric(
            id: "claude.session", label: "Session", value: "41%", fraction: 0.41, isBounded: true, hasData: true
        )
        return MenuBarContent(
            groups: [.init(providerID: "claude", displayName: "Claude", icon: .providerMark("claude"), metrics: [session])],
            bars: [session]
        )
    }
}
