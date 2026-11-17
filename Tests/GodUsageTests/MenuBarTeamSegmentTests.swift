import XCTest
@testable import GodUsage

/// The menu bar's team segment: the top line (rank, movement, spend) and the bottom line (your plan's
/// pace, the most urgent plan winning, staleness; the top line alone otherwise). Same working day as
/// `LivePaceDisplayTests`: Thursday 2026-11-05, 07:00–11:00 and 12:00–16:00 UTC, a 20% budget.
final class MenuBarTeamSegmentTests: XCTestCase {
    private func at(_ time: String) -> Date { GodUsageISO8601.date(from: "2026-11-05T\(time):00Z")! }

    private func live(used: Double, rate: Double?, at time: String) -> LivePace {
        let pace = TeamPlanPace(
            budgetPercent: 20, usedPercent: used, leftPercent: 60, ratePerHour: rate,
            hours: [.init(from: "2026-11-05T07:00:00Z", to: "2026-11-05T11:00:00Z"), .init(from: "2026-11-05T12:00:00Z", to: "2026-11-05T16:00:00Z")],
            futureDays: [.init(day: "2026-11-06", hours: 8), .init(day: "2026-11-09", hours: 8)],
            today: [], sharedWith: [], resetsAt: "2026-11-10T03:00:00Z"
        )
        return LivePace(pace: pace, now: at(time))
    }

    private func standing(rankChange: Int? = nil, share: String? = "30%", syncedAt: Date? = nil) -> MenuBarTeamSegment.Standing {
        MenuBarTeamSegment.Standing(rank: 2, rankChange: rankChange, spendUSD: 37.21, share: share, syncedAt: syncedAt)
    }

    // MARK: - Top line

    func testTopLineShowsRankMovementAndWholeDollars() {
        XCTAssertEqual(MenuBarTeamSegment.topLine(standing(rankChange: 1)), [
            MenuBarSpan("#2"), MenuBarSpan("▲1", .positive), MenuBarSpan(" · $37"),
        ])
        XCTAssertEqual(MenuBarTeamSegment.topLine(standing(rankChange: -2)), [
            MenuBarSpan("#2"), MenuBarSpan("▼2", .dim), MenuBarSpan(" · $37"),
        ])
        XCTAssertEqual(MenuBarTeamSegment.topLine(standing(rankChange: 0)), [MenuBarSpan("#2"), MenuBarSpan(" · $37")])
        XCTAssertEqual(MenuBarTeamSegment.topLine(standing()), [MenuBarSpan("#2"), MenuBarSpan(" · $37")])
    }

    // MARK: - Pace

    func testEachPaceReadsTheWayTheMockupShows() {
        // 11:30: 48 min ahead and heading over the budget.
        XCTAssertEqual(MenuBarTeamSegment.pace(live(used: 12, rate: 4, at: "11:30")), MenuBarSpan("+48m", .warning))
        // 12:30: 1h 42m under, heading well under.
        XCTAssertEqual(MenuBarTeamSegment.pace(live(used: 7, rate: 1, at: "12:30")), MenuBarSpan("−1h 42m", .positive))
        // 09:00: right on pace.
        XCTAssertEqual(MenuBarTeamSegment.pace(live(used: 5, rate: 2.5, at: "09:00")), MenuBarSpan("On pace", .dim))
        // 14:00: 26.3% of a 20% budget.
        XCTAssertEqual(MenuBarTeamSegment.pace(live(used: 26.3, rate: 2.5, at: "14:00")), MenuBarSpan("+6.3%", .chip))
    }

    func testOverBudgetBeatsAheadWhichBeatsTheRest() {
        let ahead = live(used: 12, rate: 4, at: "11:30")
        let behind = live(used: 7, rate: 1, at: "12:30")
        let over = live(used: 26.3, rate: 2.5, at: "14:00")
        let dayOff = live(used: 0, rate: nil, at: "06:00")
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([behind, ahead, over])?.state, .overBudget)
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([behind, ahead])?.state, .ahead)
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([dayOff, behind])?.state, behind.state)
        XCTAssertNil(MenuBarTeamSegment.mostUrgent([dayOff]), "outside the working day there's no pace")
        XCTAssertNil(MenuBarTeamSegment.mostUrgent([]))
    }

    func testFurtherAheadWinsBetweenTwoPlansAhead() {
        var slight = live(used: 12, rate: 4, at: "11:30")
        slight.ahead = 20 * 60
        var far = slight
        far.ahead = 90 * 60
        XCTAssertEqual(MenuBarTeamSegment.mostUrgent([slight, far])?.ahead, 90 * 60)
    }

    // MARK: - Bottom line

    func testNoBottomLineWithoutPace() {
        let now = at("09:00")
        // The share no longer fills the bottom line: it lives in the tooltip only.
        XCTAssertNil(MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: now), paces: [], now: now))
        XCTAssertNil(MenuBarTeamSegment.bottomLine(standing: standing(share: nil), paces: [], now: now))
        let ahead = live(used: 12, rate: 4, at: "11:30")
        XCTAssertEqual(
            MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: at("11:20")), paces: [ahead], now: at("11:30")),
            [MenuBarSpan("+48m", .warning)]
        )
    }

    /// Regression: the selected team has no plans, and a plan of another team covers you and runs ahead
    /// of pace. This Week's Limit showed it ("2h 51m ahead of pace") while the menu bar fell back to the
    /// share, because it only looked at the selected team's report.
    func testBottomLineUsesAnotherTeamsPlanThatCoversYou() {
        var ahead = live(used: 12, rate: 4, at: "11:30")
        ahead.ahead = 2 * 3600 + 51 * 60
        func plan(_ id: String, includesYou: Bool) -> TeamPlanReport {
            TeamPlanReport(
                id: id, provider: "claude", name: "Claude Max 100", monthlyCostUSD: 100, renewalDay: 1, memberIDs: nil,
                includesYou: includesYou,
                cycle: .init(from: "2026-11-01", to: "2026-11-30", daysElapsed: 5, daysTotal: 30, daysLeft: 25),
                valueUSD: 0, projectedValueUSD: 0, projectedMultiple: 0, underused: false
            )
        }
        func report(_ plans: [TeamPlanReport]) -> TeamPlansReport {
            TeamPlansReport(plans: plans, totals: .init(monthlyCostUSD: 0, valueUSD: 0, projectedValueUSD: 0), canEdit: false)
        }
        let entries = YourTeamPlans.merge(selectedTeamID: "tutti", reports: [
            (teamID: "tutti", report: report([])),
            (teamID: "dev", report: report([plan("max", includesYou: true), plan("other", includesYou: false)])),
        ])
        let paces = TeamPlansStore.menuBarPaces(entries) { $0.plan.id == "max" ? ahead : nil }
        XCTAssertEqual(paces.count, 1)
        XCTAssertEqual(
            MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: at("11:20")), paces: paces, now: at("11:30")),
            [MenuBarSpan("+2h 51m", .warning)]
        )
    }

    func testStaleDataSaysHowOldItIs() {
        let now = at("14:00")
        let ahead = live(used: 12, rate: 4, at: "11:30")
        XCTAssertEqual(
            MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: at("12:00")), paces: [ahead], now: now),
            [MenuBarSpan("Upd 2h", .dim)]
        )
        // Within the hour the live figure stays, and without a pace there is no bottom line.
        XCTAssertEqual(
            MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: at("13:01")), paces: [ahead], now: at("13:30"))?.count, 1
        )
        XCTAssertNil(MenuBarTeamSegment.bottomLine(standing: standing(syncedAt: at("13:01")), paces: [], now: now))
    }

    func testShareMovesIntoTheTooltip() {
        XCTAssertEqual(MenuBarTeamSegment.detail(standing()), "Team: 30% of the team’s spend today")
        XCTAssertEqual(MenuBarTeamSegment.detail(standing(share: nil)), "Team")
    }

    @MainActor
    func testTeamGroupCarriesBothLinesAndTheTooltip() {
        let over = live(used: 26.3, rate: 2.5, at: "14:00")
        let group = MenuBarContentBuilder.teamGroup(
            standing: standing(rankChange: 1, syncedAt: at("13:50")), paces: [over], now: at("14:00")
        )
        XCTAssertEqual(group.metrics.map(\.displayText), ["#2▲1 · $37", "+6.3%"])
        XCTAssertEqual(group.toolTip, "Team: 30% of the team’s spend today")
        let content = MenuBarContent(groups: [group], bars: [])
        XCTAssertTrue(content.needsColor(style: .text))
        XCTAssertNotNil(MenuBarStripRenderer.image(for: content, style: .text))
    }

    @MainActor
    func testTeamGroupWithoutPaceIsOneLineWithTheShareInTheTooltip() {
        let group = MenuBarContentBuilder.teamGroup(standing: standing(syncedAt: at("13:50")), paces: [], now: at("14:00"))
        XCTAssertEqual(group.metrics.map(\.displayText), ["#2 · $37"])
        XCTAssertEqual(group.toolTip, "Team: 30% of the team’s spend today")
        XCTAssertTrue(group.accessibilityTextIncludesShare)
    }
}

private extension MenuBarContent.Group {
    var accessibilityTextIncludesShare: Bool {
        MenuBarContent(groups: [self], bars: []).accessibilityText.contains("30% of the team’s spend today")
    }
}
