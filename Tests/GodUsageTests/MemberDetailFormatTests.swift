import XCTest
@testable import GodUsage

final class MemberDetailFormatTests: XCTestCase {
    // MARK: - Last hour

    func testLastHourTileNamesTheLevelAndSaysMostInTeamOnlyWhenTrue() {
        let fastTop = TeamMomentum(lastHourUSD: 164.15, level: 2, reasons: ["fast", "top"])
        let tile = MemberDetailFormat.lastHourTile(fastTop)
        XCTAssertEqual(tile.label, "LAST HOUR")
        XCTAssertEqual(tile.value, "+$164.15")
        XCTAssertEqual(tile.context, "Fast · most in the team")
        XCTAssertTrue(tile.isNotice)
        XCTAssertEqual(tile.accessibilityLabel, "$164.15 in the last hour · spending fast, level 2 of 3: over $5, the most in the team")

        let notTop = TeamMomentum(lastHourUSD: 6, level: 2, reasons: ["fast", "self"], typicalHourUSD: 2)
        XCTAssertEqual(MemberDetailFormat.lastHourTile(notTop).context, "Fast")
        XCTAssertEqual(MemberDetailFormat.momentumContext(TeamMomentum(lastHourUSD: 5, level: 1, reasons: ["fast"])), "Picking up")
        XCTAssertEqual(MemberDetailFormat.momentumContext(TeamMomentum(lastHourUSD: 30, level: 3, reasons: ["fast", "self", "top"])), "Very fast · most in the team")
    }

    func testLastHourTileIsQuietWithoutSpendAndPlainWithoutALevel() {
        for momentum in [nil, TeamMomentum(lastHourUSD: 0, level: 0)] {
            let tile = MemberDetailFormat.lastHourTile(momentum)
            XCTAssertEqual(tile.value, "$0.00")
            XCTAssertEqual(tile.context, "Quiet")
            XCTAssertFalse(tile.isNotice)
        }
        let slow = MemberDetailFormat.lastHourTile(TeamMomentum(lastHourUSD: 0.5, level: 0, reasons: []))
        XCTAssertEqual(slow.value, "+$0.50")
        XCTAssertEqual(slow.context, "Normal pace")
        XCTAssertFalse(slow.isNotice)
    }

    // MARK: - Pace, efficiency, place

    func testPaceTileRoundsToWholeDollarsAndCountsDaysLeft() {
        let tile = MemberDetailFormat.paceTile(TeamProjection(spentSoFar: 1000, projected: 2404.37, monthName: "November", daysLeft: 13))
        XCTAssertEqual(tile.label, "NOVEMBER PACE")
        XCTAssertEqual(tile.value, "$2,404")
        XCTAssertEqual(tile.context, "13 days left")
        XCTAssertEqual(MemberDetailFormat.paceTile(TeamProjection(spentSoFar: 1, projected: 1, monthName: "May", daysLeft: 1)).context, "1 day left")
        XCTAssertEqual(MemberDetailFormat.paceTile(TeamProjection(spentSoFar: 1, projected: 1, monthName: "May", daysLeft: 0)).context, "Last day")
    }

    func testEfficiencyTileNeedsTokens() {
        let tile = MemberDetailFormat.efficiencyTile(UsageTotals(tokens: 2_000_000, costUSD: 0.78))
        XCTAssertEqual(tile?.value, "$0.39")
        XCTAssertEqual(tile?.context, "per million tokens")
        XCTAssertNil(MemberDetailFormat.efficiencyTile(UsageTotals(tokens: 0, costUSD: 0)))
    }

    func testPlaceAndMovementWording() {
        XCTAssertEqual(MemberDetailFormat.placeText(rank: 1, of: 2), "1st of 2")
        XCTAssertEqual(MemberDetailFormat.placeText(rank: 3, of: 6), "3rd of 6")
        XCTAssertEqual(MemberDetailFormat.movementText(rankChange: 0, hasUsage: true, range: .today), "Same as yesterday")
        XCTAssertEqual(MemberDetailFormat.movementText(rankChange: 2, hasUsage: true, range: .today), "Up 2 since yesterday")
        XCTAssertEqual(MemberDetailFormat.movementText(rankChange: -1, hasUsage: true, range: .today), "Down 1 since yesterday")
        XCTAssertEqual(MemberDetailFormat.movementText(rankChange: nil, hasUsage: true, range: .today), "New")
        XCTAssertNil(MemberDetailFormat.movementText(rankChange: nil, hasUsage: false, range: .today))
        XCTAssertEqual(MemberDetailFormat.movementText(rankChange: 1, hasUsage: true, range: .week), "Up 1 since the previous 7 days")
        XCTAssertNil(MemberDetailFormat.movementText(rankChange: 2, hasUsage: true, range: .year))

        let tile = MemberDetailFormat.placeTile(rank: 1, of: 2, rankChange: 0, hasUsage: true, range: .today)
        XCTAssertEqual(tile.label, "PLACE")
        XCTAssertEqual(tile.value, "1st of 2")
        XCTAssertEqual(tile.context, "Same as yesterday")
    }

    // MARK: - Chips

    func testAwardsKeepShortTitlesAndFullSentences() {
        let champion = TeamChampion(month: "2026-10", userID: "u1", displayName: "Andrea", costUSD: 900)
        let awards = MemberDetailFormat.awards(isTopToday: true, champion: champion)
        XCTAssertEqual(awards.map(\.title), ["Top today", "October champion"])
        XCTAssertEqual(awards.map(\.symbol), ["crown.fill", "trophy.fill"])
        XCTAssertEqual(awards.map(\.detail), ["Top spender today", "October 2026 champion: top spender of the month"])
        XCTAssertTrue(MemberDetailFormat.awards(isTopToday: false, champion: nil).isEmpty)
    }

    // MARK: - Shares

    private func provider(_ id: String, _ cost: Double, tokens: Int = 1000) -> TeamStats.ProviderTotals {
        TeamStats.ProviderTotals(provider: id, tokens: tokens, costUSD: cost)
    }

    func testProvidersAreHiddenWithASingleProvider() {
        let name: (String) -> String = { $0.capitalized }
        XCTAssertTrue(MemberDetailFormat.providerShares([provider("claude", 72.55)], metric: .spend, providerName: name).isEmpty)
        // A provider with nothing in this metric doesn't count as a second one.
        XCTAssertTrue(MemberDetailFormat.providerShares([provider("claude", 72.55), provider("codex", 0, tokens: 0)], metric: .spend, providerName: name).isEmpty)

        let shares = MemberDetailFormat.providerShares([provider("codex", 25), provider("claude", 75)], metric: .spend, providerName: name)
        XCTAssertEqual(shares.map(\.title), ["Claude", "Codex"])
        XCTAssertEqual(shares.map(\.fraction), [0.75, 0.25])
    }

    func testModelSharesAreTheMembersOwnLargestFirstWithTheRestAsOther() {
        func model(_ name: String, _ mine: Double, others: Double = 10) -> TeamStats.Model {
            TeamStats.Model(model: name, provider: "claude", tokens: 100, costUSD: mine + others, members: [
                TeamStats.MemberTotals(userID: "me", tokens: 50, costUSD: mine),
                TeamStats.MemberTotals(userID: "them", tokens: 50, costUSD: others),
            ])
        }
        let models = [model("sonnet", 2.07), model("opus", 70.47), model("haiku", 0), model("teammate-only", 0)]
        let shares = MemberDetailFormat.modelShares(models, userID: "me", metric: .spend)
        XCTAssertEqual(shares.map(\.title), ["opus", "sonnet"])
        XCTAssertEqual(shares.map { MemberDetailFormat.percentText($0.fraction) }, ["97%", "3%"])
        XCTAssertEqual(shares.first?.totals.costUSD, 70.47)
        XCTAssertEqual(shares.first?.id, "claude/opus")

        let many = (1...7).map { model("m\($0)", Double(8 - $0)) }
        let limited = MemberDetailFormat.modelShares(many, userID: "me", metric: .spend, limit: 5)
        XCTAssertEqual(limited.map(\.title), ["m1", "m2", "m3", "m4", "m5", "2 more"])
        XCTAssertNil(limited.last?.provider)
        XCTAssertEqual(limited.last?.totals.costUSD, 3)
        XCTAssertEqual(limited.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
    }

    func testCostPerMtokSharesFollowSpend() {
        let shares = MemberDetailFormat.providerShares(
            [provider("claude", 30, tokens: 1_000_000), provider("codex", 10, tokens: 100_000)],
            metric: .costPerMtok, providerName: { $0 }
        )
        XCTAssertEqual(shares.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(shares.map(\.fraction), [0.75, 0.25])
    }

    func testPercentText() {
        XCTAssertEqual(MemberDetailFormat.percentText(0.971), "97%")
        XCTAssertEqual(MemberDetailFormat.percentText(0.003), "<1%")
        XCTAssertEqual(MemberDetailFormat.percentText(1), "100%")
        XCTAssertEqual(MemberDetailFormat.listTitle("Models", range: .today), "MODELS TODAY")
        XCTAssertEqual(MemberDetailFormat.listTitle("Providers", range: .week), "PROVIDERS 7 DAYS")
    }

    // MARK: - Reactions and footer

    func testReactionGiversListFirstNamesOnceAndEveryoneInTheTooltip() {
        let reactions = MemberReactions(fire: 2, clap: 1, clown: 0, mine: [.clap], from: ["fire": ["u2", "u3"], "clap": ["me", "u2"], "clown": []])
        let names = ["u2": "Matteo Rossi", "u3": "Daniele Bianchi", "me": "Andrea Montinovo"]
        let givers = MemberDetailFormat.reactionGivers(reactions, names: names, me: "me")
        XCTAssertEqual(givers?.summary, "Matteo, Daniele, You")
        XCTAssertEqual(givers?.detail, "🔥 Matteo Rossi, Daniele Bianchi\n👏 You, Matteo Rossi")
        XCTAssertNil(MemberDetailFormat.reactionGivers(.none, names: names, me: "me"))
        // Older servers say how many, not who.
        XCTAssertNil(MemberDetailFormat.reactionGivers(MemberReactions(fire: 1, clap: 0, clown: 0, mine: []), names: names, me: "me"))
    }

    func testFooterLeavesTheVersionToTheChipWhenOutdated() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let synced = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 60))
        XCTAssertEqual(MemberDetailFormat.footerText(lastSyncAt: synced, appVersion: "1.3.3-dev", isOutdated: false, now: now), "Updated 5m ago · v1.3.3-dev")
        XCTAssertEqual(MemberDetailFormat.footerText(lastSyncAt: synced, appVersion: "1.3.3", isOutdated: true, now: now), "Updated 5m ago")
        XCTAssertEqual(MemberDetailFormat.footerText(lastSyncAt: nil, appVersion: nil, isOutdated: false, now: now), "Not synced yet")
    }

    // MARK: - Month names

    func testMonthNamesAreEnglishWhateverTheMacsLanguage() {
        XCTAssertEqual(TeamsFormat.monthName(10), "October")
        XCTAssertEqual(TeamsFormat.monthName(11), "November")
        let champion = TeamChampion(month: "2026-10", userID: "u1", displayName: "Andrea", costUSD: 1)
        XCTAssertEqual(champion.monthLabel, "October 2026")
        XCTAssertEqual(champion.monthName, "October")

        var italian = Calendar(identifier: .gregorian)
        italian.locale = Locale(identifier: "it_IT")
        italian.timeZone = TimeZone(identifier: "Europe/Rome")!
        let projection = TeamProjection.make(spentSoFar: 100, from: "2026-11-01", to: "2026-11-17", calendar: italian)
        XCTAssertEqual(projection?.monthName, "November")
        XCTAssertEqual(projection?.daysLeft, 13)
    }
}
