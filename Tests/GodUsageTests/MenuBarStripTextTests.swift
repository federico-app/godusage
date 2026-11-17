import XCTest
@testable import GodUsage

/// The Text strip's decisions: the S/W prefix, what a value reads (percent, orange with the time to
/// the limit, the session countdown, the reset time), the badges, and the exhausted reset.
@MainActor
final class MenuBarStripTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    // MARK: - Labels

    func testPrefixComesFromTheMetricNotItsPosition() {
        XCTAssertEqual(MenuBarMetricLabel.prefix(limitKeys: ["session"]), "S")
        XCTAssertEqual(MenuBarMetricLabel.prefix(limitKeys: ["weekly"]), "W")
        // Antigravity's main (Gemini) pool.
        XCTAssertEqual(MenuBarMetricLabel.prefix(limitKeys: ["geminiSession"]), "S")
        XCTAssertEqual(MenuBarMetricLabel.prefix(limitKeys: ["geminiWeekly"]), "W")
        // Separate model pools and everything else get no letter.
        for keys in [["nonGeminiSession"], ["nonGeminiWeekly"], ["argonWeekly"], ["spark"], ["sparkWeekly"],
                     ["sonnet"], ["totalUsage"], ["premiumCredits"], ["webSearches"], ["monthly"], []] {
            XCTAssertNil(MenuBarMetricLabel.prefix(limitKeys: keys), "\(keys)")
        }
    }

    func testRealProviderDescriptorsGetTheirLetters() {
        let defaults = UserDefaults(suiteName: "MenuBarStripTextTests.\(UUID().uuidString)")!
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: defaults))
        func prefix(_ id: String) -> String? {
            guard let descriptor = registry.descriptors.first(where: { $0.id == id }) else {
                XCTFail("missing \(id)")
                return nil
            }
            return MenuBarMetricLabel.prefix(for: descriptor)
        }
        for provider in ["claude", "codex", "muse", "zai"] {
            XCTAssertEqual(prefix("\(provider).session"), "S", provider)
            XCTAssertEqual(prefix("\(provider).weekly"), "W", provider)
        }
        XCTAssertEqual(prefix(AntigravityMetric.geminiID), "S")
        XCTAssertEqual(prefix(AntigravityMetric.geminiWeeklyID), "W")
        XCTAssertNil(prefix(AntigravityMetric.claudeID))
        XCTAssertNil(prefix(AntigravityMetric.claudeWeeklyID))
        XCTAssertNil(prefix("codex.spark"))
        XCTAssertNil(prefix("copilot.premium"))
        XCTAssertNil(prefix("cursor.auto"))
        XCTAssertNil(prefix("cursor.api"))
    }

    // MARK: - Value text

    private func window(used: Double, resetsIn: TimeInterval, period: TimeInterval) -> WidgetData {
        var data = WidgetData(title: "W", icon: .providerMark("claude"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetsIn)
        data.periodDurationMs = Int(period * 1000)
        return data
    }

    private func spans(_ data: WidgetData, prefix: String?) -> [MenuBarSpan] {
        MenuBarValueText.spans(value: data.menuBarValue, prefix: prefix, data: data, now: now)
    }

    func testHealthyValueStaysPlain() {
        let data = window(used: 20, resetsIn: 4 * 24 * hour, period: 7 * 24 * hour)
        XCTAssertEqual(spans(data, prefix: "W"), [MenuBarSpan("20%")])
    }

    func testOverPaceTurnsOrangeWithTheTimeToTheLimit() {
        // 60% used two days into a week: on pace to run out about 1.3 days from now.
        let data = window(used: 60, resetsIn: 5 * 24 * hour, period: 7 * 24 * hour)
        guard case .runningOut = data.meterState(now: now) else { return XCTFail("expected running out") }
        let result = spans(data, prefix: "W")
        XCTAssertEqual(result, [MenuBarSpan("60%·1d", .warning)])
    }

    func testSessionUnderTenPercentLeftShowsTheResetCountdown() {
        let data = window(used: 92, resetsIn: 38 * 60, period: 5 * hour)
        XCTAssertEqual(spans(data, prefix: "S"), [MenuBarSpan("↻38m", .warning)])
        // The same reading on a weekly window is not a session: no countdown.
        XCTAssertNotEqual(spans(data, prefix: "W").first?.text, "↻38m")
    }

    func testUsedUpLimitShowsTheResetTimeDimmed() {
        let data = window(used: 100, resetsIn: 2 * 24 * hour + 4 * hour, period: 7 * 24 * hour)
        XCTAssertEqual(spans(data, prefix: nil), [MenuBarSpan("↻2d 4h", .dim)])
    }

    func testUnboundedValueStaysPlain() {
        let data = WidgetData(title: "Today", icon: .providerMark("cursor"), kind: .dollars, used: 12, limit: nil)
        XCTAssertEqual(spans(data, prefix: nil), [MenuBarSpan(data.menuBarValue)])
    }

    func testCompactTimes() {
        XCTAssertEqual(MenuBarValueText.limitETA(3 * 24 * hour + 17 * hour), "3d")
        XCTAssertEqual(MenuBarValueText.limitETA(17 * hour + 59 * 60), "17h")
        XCTAssertEqual(MenuBarValueText.limitETA(45 * 60), "45m")
        XCTAssertEqual(MenuBarValueText.limitETA(10), "1m")
        XCTAssertNil(MenuBarValueText.limitETA(0))
        XCTAssertEqual(MenuBarValueText.resetText(38 * 60), "↻38m")
        XCTAssertEqual(MenuBarValueText.resetText(2 * 24 * hour + 4 * hour), "↻2d 4h")
        XCTAssertNil(MenuBarValueText.resetText(-5))
    }

    // MARK: - Badges

    func testLoginBadgeOutranksTheSwitchSuggestion() {
        XCTAssertEqual(MenuBarBadge.decide(loginRequired: true, isSwitchTarget: true), .loginRenewal)
        XCTAssertEqual(MenuBarBadge.decide(loginRequired: false, isSwitchTarget: true), .useNow)
        XCTAssertNil(MenuBarBadge.decide(loginRequired: false, isSwitchTarget: false))
    }

    func testSwitchTargetGetsTheGreenDotAndColor() {
        let content = MenuBarContentBuilder.build(
            groups: [group("claude", percent("claude.weekly", "weekly", 20)), group("codex", percent("codex.weekly", "weekly", 10))],
            data: { $0.sample }, switchTargets: ["codex"], now: now
        )
        XCTAssertEqual(content.groups.map(\.badge), [nil, .useNow])
        XCTAssertTrue(content.needsColor(style: .text))
        XCTAssertFalse(content.needsColor(style: .bars), "Bars only show badges on faded icons")
        XCTAssertEqual(content.groups[0].metrics.first?.prefix, "W")
        XCTAssertNotNil(MenuBarStripRenderer.image(for: content, style: .text))
    }

    func testLoginFailureWithoutStarsStillShowsAFadedIconWithTheOrangeDot() {
        let unstarred = ProviderMetrics(provider: Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude")), metrics: [])
        let failing = MenuBarContentBuilder.build(groups: [unstarred], data: { $0.sample }, loginRequired: { _ in true }, now: now)
        XCTAssertEqual(failing.groups.count, 1)
        XCTAssertTrue(failing.groups[0].loginRequired)
        XCTAssertEqual(failing.groups[0].badge, .loginRenewal)
        XCTAssertNotNil(MenuBarStripRenderer.image(for: failing, style: .text))
        // Fine (or a network error, which isn't a login failure): an unstarred provider stays hidden.
        XCTAssertTrue(MenuBarContentBuilder.build(groups: [unstarred], data: { $0.sample }, now: now).isEmpty)
    }

    func testExhaustedWeeklyShowsTheTimeToItsReset() {
        var sample = WidgetData(title: "Weekly", icon: .providerMark("claude"), kind: .percent, used: 100, limit: 100)
        sample.resetsAt = now.addingTimeInterval(2 * 24 * hour + 4 * hour)
        let weekly = WidgetDescriptor(id: "claude.weekly", providerID: "claude", metricLabel: "Weekly", sample: sample)
            .exportingLimit("weekly", unit: "percent")
        let content = MenuBarContentBuilder.build(groups: [group("claude", weekly)], data: { $0.sample }, now: now)
        XCTAssertTrue(content.groups[0].isExhausted)
        XCTAssertEqual(content.groups[0].resetText, "↻2d 4h")
        XCTAssertTrue(content.accessibilityText.contains("Resets ↻2d 4h"))
        XCTAssertFalse(content.needsColor(style: .text), "the dimmed reset stays a template")
    }

    func testPoolResetIsTheFirstExhaustedPool() {
        func pool(_ id: String, key: String, used: Double, resetsIn: TimeInterval) -> WidgetDescriptor {
            var sample = WidgetData(title: id, icon: .providerMark("antigravity"), kind: .percent, used: used, limit: 100)
            sample.resetsAt = now.addingTimeInterval(resetsIn)
            return WidgetDescriptor(id: id, providerID: "antigravity", metricLabel: id, sample: sample)
                .exportingLimit(key, unit: "percent")
        }
        let descriptors = [
            pool("a.gw", key: "geminiWeekly", used: 100, resetsIn: 3 * hour),
            pool("a.cw", key: "nonGeminiWeekly", used: 100, resetsIn: 2 * hour),
            pool("a.s", key: "geminiSession", used: 100, resetsIn: hour),
        ]
        XCTAssertEqual(
            WeeklyQuotaVisibility.menuBarExhaustedResetsAt(descriptors: descriptors, data: { $0.sample }),
            now.addingTimeInterval(2 * hour)
        )
    }

    // MARK: - Fixtures

    private func group(_ id: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        ProviderMetrics(provider: Provider(id: id, displayName: id.capitalized, icon: .providerMark(id)), metrics: metrics)
    }

    private func percent(_ id: String, _ key: String, _ used: Double) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id, providerID: String(id.prefix { $0 != "." }), metricLabel: key,
            sample: WidgetData(title: key, icon: .providerMark("claude"), kind: .percent, used: used, limit: 100)
        ).exportingLimit(key, unit: "percent")
    }
}
