import XCTest
@testable import GodUsage

/// Layout defaults and migration behavior for Antigravity's four metrics (merged quota pools +
/// weekly limits fix). Uses the real provider's registry — `MockData` carries no Antigravity
/// fixtures — with the real `DefaultLayout` seeds.
@MainActor
final class AntigravityLayoutTests: XCTestCase {

    func testFreshDefaultsSeedFiveMetricsTwoPinsAndClaudePairSecondary() {
        let store = makeStore("FreshDefaults")

        // All five metrics enabled, in declaration order (Argon Weekly right after Weekly).
        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.argonWeekly",
            "antigravity.claude", "antigravity.claudeWeekly"
        ])

        // The Gemini pair is pinned (2-per-provider cap), mirroring Claude/Codex Session+Weekly.
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])

        // Gemini pair and Argon Weekly above the fold; the Claude pool pair below the caret.
        let group = store.customizeGroups.first { $0.provider.id == "antigravity" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.argonWeekly"
        ])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), ["antigravity.claude", "antigravity.claudeWeekly"])
    }

    func testArgonUpgradeSeedsOnceAndPreservesSavedPinsOrderAndOptOuts() {
        let defaults = makeDefaults("ArgonUpgrade")
        let previousIDs = preArgonMetricIDs
        // The saved order from the previous release; Argon slots in at its declared position.
        let savedOrder = previousIDs
        // The previous release already offered every old metric; the user disabled Gemini Weekly.
        saveStored(previousIDs.filter { $0 != "antigravity.geminiWeekly" }.map {
            PlacedWidget(descriptorID: $0)
        }, forKey: "layout", in: defaults)
        saveStored(previousIDs, forKey: "layout.seededDefaults", in: defaults)
        saveStored(["antigravity": savedOrder], forKey: "layout.metricOrderByProvider", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.menuBarPins")
        defaults.set(["antigravity.geminiPro"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.placed.filter { $0.descriptorID == "antigravity.argonWeekly" }.count, 1)
        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.claude"])
        XCTAssertEqual(store.expandedMetricIDs, ["antigravity.geminiPro"])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "antigravity").map(\.id), [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.argonWeekly",
            "antigravity.claude", "antigravity.claudeWeekly"
        ])

        store.setMetricEnabled("antigravity.argonWeekly", false)
        let reloaded = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.isMetricEnabled("antigravity.argonWeekly"), "the new default is offered only once")
        XCTAssertFalse(reloaded.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertEqual(reloaded.pinnedMetricIDs, ["antigravity.claude"])
    }

    func testBothResetActionsRestoreArgonEnabledAlwaysVisibleUnpinnedAfterGeminiWeekly() {
        for resetAll in [false, true] {
            let defaults = makeDefaults("ArgonReset-\(resetAll)")
            let allIDs = preArgonMetricIDs + ["antigravity.argonWeekly"]
            saveStored(preArgonMetricIDs.map { PlacedWidget(descriptorID: $0) }, forKey: "layout", in: defaults)
            saveStored(allIDs, forKey: "layout.seededDefaults", in: defaults)
            saveStored(["antigravity": ["antigravity.argonWeekly"] + preArgonMetricIDs],
                       forKey: "layout.metricOrderByProvider", in: defaults)
            defaults.set(["antigravity.argonWeekly"], forKey: "layout.menuBarPins")
            defaults.set(["antigravity.argonWeekly"], forKey: "layout.expandedMetrics")
            let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

            if resetAll {
                store.resetToDefault()
            } else {
                store.resetProvider("antigravity")
            }

            XCTAssertTrue(store.isMetricEnabled("antigravity.argonWeekly"))
            XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.argonWeekly"))
            XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])
            XCTAssertEqual(Array(store.orderedSupportedMetrics(for: "antigravity").prefix(3).map(\.id)), [
                "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.argonWeekly"
            ])
        }
    }

    func testExistingUserLayoutAutoSeedsWeeklyMetricsBelowCaretForClaudePool() {
        // A layout from before the weekly metrics shipped: Antigravity is absent from the migration
        // baseline, so `seedNewDefaultMetrics` auto-enables both new weekly metrics once. Claude
        // Weekly (a default-expanded metric) enters below the caret; metrics the user already lived
        // with stay always-shown.
        let defaults = makeDefaults("SeedWeeklies")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.argonWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claudeWeekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.claudeWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.geminiWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.argonWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.claude"),
                       "a metric the user already lived with is never silently tucked away")
    }

    func testSavedGeminiFlashStateStaysInvisibleWhileItsTombstonesAreRetained() {
        // `antigravity.geminiFlash` no longer exists, so live registry lookups keep it out of the UI.
        // Its saved state remains as a harmless tombstone because an unknown descriptor can also be a
        // temporarily absent account card, whose customization must return on the next launch.
        let defaults = makeDefaults("FlashFilter")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.geminiFlash"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)
        defaults.set(["antigravity.geminiPro", "antigravity.geminiFlash"], forKey: "layout.menuBarPins")
        saveStored(
            ["antigravity": ["antigravity.geminiFlash", "antigravity.geminiPro", "antigravity.claude"]],
            forKey: "layout.metricOrderByProvider", in: defaults
        )

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiFlash"))
        XCTAssertFalse(store.orderedSupportedMetrics(for: "antigravity").map(\.id).contains("antigravity.geminiFlash"))
        XCTAssertFalse(store.isPinned("antigravity.geminiFlash"), "the dead pin stays invisible")
        XCTAssertTrue(
            store.pinnedMetricIDs.contains("antigravity.geminiFlash"),
            "…but its tombstone is retained for a possible return"
        )
        XCTAssertTrue(store.isPinned("antigravity.geminiPro"))
        XCTAssertFalse(store.isPinned("antigravity.geminiWeekly"), "an existing pin set gains no new defaults")
    }

    func testAbsentPinsKeyAdoptsGeminiWeeklyPinOnUpgrade() {
        // Pins re-derive from current defaults whenever the pins key is absent, and init never
        // persists pins — so an existing user who never touched pins automatically gains the
        // Gemini Weekly pin (still within the 2-per-provider cap).
        let defaults = makeDefaults("PinsAbsent")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])
    }

    func testSavedPinsKeyIsRespectedExactly() {
        let defaults = makeDefaults("PinsPresent")
        saveStored([PlacedWidget(descriptorID: "antigravity.geminiPro")], forKey: "layout", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.menuBarPins")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.claude"],
                       "a user-saved pin set must not gain the new default pins")
    }

    // MARK: - Fixtures

    private var preArgonMetricIDs: [String] {
        ["antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly"]
    }

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .antigravityOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "GodUsageTests.AntigravityLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// A registry with just the live Antigravity provider, so `DefaultLayout`'s seeds filter down to
    /// its four metrics.
    @MainActor
    static var antigravityOnly: WidgetRegistry { .from([AntigravityProvider()]) }
}
