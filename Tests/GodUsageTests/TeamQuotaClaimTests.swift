import XCTest
@testable import GodUsage

/// Claimed limit resets in the Teams quota log: Claude keeps the weekly reset time when a reset is
/// claimed, so the week gets another full limit and counts the share before the claim plus the share after.
final class TeamQuotaClaimTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_201_600) // 2026-10-05 12:00 UTC
    private let hour: TimeInterval = 3_600
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A weekly reading of the week that resets Friday Oct 9 00:00 UTC, `at` hours after the test clock.
    private func reading(_ percent: Double, at hours: Double, provider: String = "claude") -> TeamQuotaReading {
        TeamQuotaReading(
            provider: provider, cardID: provider, accountKey: nil,
            endsAt: Date(timeIntervalSince1970: 1_791_504_000), periodHours: 168,
            percent: percent, observedAt: now.addingTimeInterval(hours * hour)
        )
    }

    private func record(_ log: inout TeamQuotaLog, _ reading: TeamQuotaReading, claims: [RecordedResetClaim] = []) {
        log.record([reading], perDeviceKey: { _ in "acct" }, now: now, recordedClaims: claims) {
            DailyUsageAccumulator.dayKey(from: $0, calendar: self.utc)
        }
    }

    private func claim(at hours: Double, cleared: [String] = ["five_hour", "seven_day"]) -> RecordedResetClaim {
        RecordedResetClaim(cardID: "claude", at: now.addingTimeInterval(hours * hour), cleared: cleared)
    }

    func testASharpDropWithTheSameResetIsAClaimedResetThatAddsALimit() throws {
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -2))
        record(&log, reading(40, at: 0))
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims.map(\.percent), [95])
        XCTAssertEqual(window.claims.first?.recorded, false)
        XCTAssertEqual(window.claims.first?.after, now.addingTimeInterval(-2 * hour))
        XCTAssertEqual(window.percent, 40)
        XCTAssertEqual(window.used, 135)

        let wire = try XCTUnwrap(log.wire.first)
        XCTAssertEqual(wire.percent, 40)
        XCTAssertEqual(wire.days, [TeamQuotaLog.Day(day: "2026-10-05", percent: 135)], "today counts the use before the claim and after it")
        XCTAssertEqual(wire.claims, [TeamUsageUpload.QuotaClaim(at: "2026-10-05T12:00:00Z", after: "2026-10-05T10:00:00Z", percent: 95, day: "2026-10-05", recorded: false)])
        XCTAssertEqual(wire.since, "2026-10-05T12:00:00Z", "the stretch since the claim began with it")
    }

    func testRoundingDipsAndSmallRepricingAreNotClaims() throws {
        var log = TeamQuotaLog()
        record(&log, reading(55, at: -3))
        record(&log, reading(54, at: -2))
        record(&log, reading(51, at: -1))
        XCTAssertEqual(log.windows.first?.claims, [])
        XCTAssertEqual(log.windows.first?.percent, 55)
        XCTAssertTrue(TeamQuotaLog.isClaimDrop(from: 8, to: 0), "a claim made with little used still counts")
        XCTAssertFalse(TeamQuotaLog.isClaimDrop(from: 90, to: 80), "under a quarter of what was used")
        XCTAssertFalse(TeamQuotaLog.isClaimDrop(from: 4, to: 0), "under five points")
    }

    func testAShareReadAsZeroOnceIsAGlitchNotAClaim() throws {
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -1))
        record(&log, reading(0, at: -0.5))
        record(&log, reading(95, at: 0))
        XCTAssertEqual(log.windows.first?.claims, [])
        XCTAssertEqual(log.windows.first?.used, 95)
    }

    func testCountsTwoClaimsInOneWeek() throws {
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -30))
        record(&log, reading(0, at: -28))
        record(&log, reading(100, at: -4))
        record(&log, reading(10, at: 0))
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims.map(\.percent), [95, 100])
        XCTAssertEqual(window.used, 205)
    }

    func testAClaimGodUsageMadeCountsOnceWhetherTheDropIsReadBeforeOrAfter() throws {
        // Recorded before the next reading: the claim takes its exact time and the drop isn't a second one.
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -2))
        record(&log, reading(3, at: 0), claims: [claim(at: -1)])
        var window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims.map(\.recorded), [true])
        XCTAssertEqual(window.claims.first?.at, now.addingTimeInterval(-hour))
        XCTAssertEqual(window.used, 98)

        // The drop read first (inferred), the recorded claim folded in on the next pass: still one claim.
        log = TeamQuotaLog()
        record(&log, reading(95, at: -2))
        record(&log, reading(3, at: -0.5))
        record(&log, reading(4, at: 0), claims: [claim(at: -1)])
        window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims.count, 1)
        XCTAssertEqual(window.claims.first?.recorded, true)
        XCTAssertEqual(window.claims.first?.at, now.addingTimeInterval(-hour))
        XCTAssertEqual(window.used, 99)
        // Folding the same recorded claim again changes nothing.
        record(&log, reading(4, at: 0.1), claims: [claim(at: -1)])
        XCTAssertEqual(log.windows.first?.claims.count, 1)
    }

    func testAFableOnlyResetLeavesTheGeneralWeeklyLimitAlone() throws {
        XCTAssertEqual(ResetClaimWindow.windows(cleared: ["five_hour", "seven_day", "seven_day_overage_included"]), [.session, .weekly])
        XCTAssertEqual(ResetClaimWindow.windows(cleared: ["seven_day_fable"]), [.model("fable")])
        XCTAssertEqual(ResetClaimWindow.windows(cleared: ["weekly_scoped_Fable"]), [.model("fable")])
        XCTAssertEqual(ResetClaimWindow.windows(cleared: ["seven_day_sonnet"]), [.model("sonnet")])
        XCTAssertEqual(ResetClaimWindow.windows(cleared: ["something_new"]), [])

        var log = TeamQuotaLog()
        record(&log, reading(95, at: -2))
        record(&log, reading(96, at: 0), claims: [claim(at: -1, cleared: ["seven_day_fable"])])
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims, [])
        XCTAssertEqual(window.used, 96)
    }

    func testIgnoresAReadingFromBeforeTheLastClaim() throws {
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -2))
        record(&log, reading(5, at: 0))
        // A stale snapshot from before the claim, folded late.
        record(&log, reading(90, at: -3))
        XCTAssertEqual(log.windows.first?.percent, 5)
        XCTAssertEqual(log.windows.first?.used, 100)
    }

    func testSkipsAClaimMadeBeforeThisMacFirstReadTheWindow() throws {
        var log = TeamQuotaLog()
        record(&log, reading(4, at: 0), claims: [claim(at: -1)])
        record(&log, reading(5, at: 0.5), claims: [claim(at: -1)])
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims, [], "no share before it to count; a Mac that read it reports it")
        XCTAssertEqual(window.used, 5)
    }

    func testAStaleRefreshThatLandsRightAfterAClaimIsNotASecondClaim() throws {
        // A periodic refresh read 95% before the claim and landed after it; then the real reading.
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -1))
        record(&log, reading(95, at: -0.1), claims: [claim(at: -0.2)])
        record(&log, reading(1, at: 0), claims: [claim(at: -0.2)])
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.claims.map(\.percent), [95])
        XCTAssertEqual(window.claims.map(\.recorded), [true])
        XCTAssertEqual(window.used, 96)
    }

    func testAPlanUpgradeOrARaisedLimitIsNotAClaim() throws {
        // Pro to Max: the plan changed with the drop.
        var log = TeamQuotaLog()
        var pro = reading(80, at: -6)
        pro.plan = "Pro"
        var max = reading(16, at: 0)
        max.plan = "Max 5x"
        record(&log, pro)
        record(&log, max)
        XCTAssertEqual(log.windows.first?.claims, [])
        // A raised limit halves the share between two readings 15 minutes apart: too much use to be fresh.
        log = TeamQuotaLog()
        record(&log, reading(60, at: -0.25))
        record(&log, reading(30, at: 0))
        XCTAssertEqual(log.windows.first?.claims, [])
        XCTAssertEqual(log.windows.first?.used, 60)
    }

    func testAZeroReadOnceBeforeTheMacSleptIsUndoneWhenTheShareComesBack() throws {
        var log = TeamQuotaLog()
        record(&log, reading(95, at: -5))
        record(&log, reading(0, at: -4.9))
        XCTAssertEqual(log.windows.first?.claims.count, 1)
        record(&log, reading(95, at: 0))
        XCTAssertEqual(log.windows.first?.claims, [])
        XCTAssertEqual(log.windows.first?.used, 95)
    }

    func testMergingACardsPerMacCopyPutsItsOldShareBeforeTheClaim() throws {
        var log = TeamQuotaLog()
        let perDevice = { (reading: TeamQuotaReading) in "dev-\(reading.cardID)" }
        func read(_ percent: Double, at hours: Double, card: String, account: String?) {
            var reading = reading(percent, at: hours)
            reading.cardID = card
            reading.accountKey = account
            log.record([reading], perDeviceKey: perDevice, now: now) { DailyUsageAccumulator.dayKey(from: $0, calendar: self.utc) }
        }
        read(95, at: -3, card: "claude@b", account: "key")
        read(10, at: -1, card: "claude@b", account: "key")
        // This card's copy, named per Mac, last read before the claim.
        read(95, at: -2.5, card: "claude", account: nil)
        read(12, at: 0, card: "claude", account: "key")
        let window = try XCTUnwrap(log.windows.first { $0.account == "key" })
        XCTAssertEqual(log.windows.count, 1)
        XCTAssertEqual(window.claims.map(\.percent), [95])
        XCTAssertEqual(window.used, 107)

        // A claim GodUsage made with an unknown share never hides the real one.
        var recorded = window
        recorded.claims = [TeamQuotaLog.Claim(at: now, after: now, percent: 0, day: "2026-10-05", recorded: true)]
        recorded.mergeClaims([TeamQuotaLog.Claim(at: now.addingTimeInterval(600), after: now.addingTimeInterval(-3_600), percent: 95, day: "2026-10-05", recorded: false)])
        XCTAssertEqual(recorded.claims.map(\.percent), [95])
        XCTAssertEqual(recorded.claims.map(\.recorded), [true])
        XCTAssertEqual(recorded.claims.first?.at, now)
    }

    func testKeepsTheLatestClaimsWithoutLosingTheirUse() throws {
        var window = TeamQuotaLog.Window(provider: "claude", account: "acct", endsAt: now, periodHours: 168, percent: 3, observedAt: now)
        window.claims = (0..<25).map { TeamQuotaLog.Claim(at: now.addingTimeInterval(Double($0) * 60), after: now, percent: 1, day: "2026-10-05", recorded: false) }
        window.trimClaims()
        XCTAssertEqual(window.claims.count, TeamQuotaLog.maxClaims)
        XCTAssertEqual(window.claims.first?.percent, 6)
        XCTAssertEqual(window.used, 28)
    }

    func testCodexStartsANewWeekInsteadOfAddingAClaim() throws {
        var log = TeamQuotaLog()
        record(&log, reading(70, at: -1, provider: "codex"))
        var fresh = reading(2, at: 0, provider: "codex")
        fresh.endsAt = now.addingTimeInterval(168 * hour)
        record(&log, fresh)
        XCTAssertEqual(log.windows.map(\.percent), [70, 2])
        XCTAssertEqual(log.windows.map(\.claims), [[], []])
        XCTAssertEqual(log.windows.first?.endsAt, now)
    }

    func testOnlyClaudeLimitWindowsSendClaims() throws {
        var log = TeamQuotaLog()
        var session = reading(60, at: 0)
        session.kind = .session
        session.periodHours = 5
        record(&log, session)
        record(&log, reading(20, at: 0))
        XCTAssertEqual(log.wire.map(\.claims), [[], nil])
        let saved = #"{"windows":[{"provider":"claude","account":"acct","endsAt":800000000,"periodHours":168,"percent":40,"observedAt":799990000}]}"#
        XCTAssertEqual(try JSONDecoder().decode(TeamQuotaLog.self, from: Data(saved.utf8)).windows.first?.claims, [])
    }

    func testTheClaimTakesTheWindowsTheAnswerNamesElseTheGrants() {
        let answer = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"result":"reset","cleared":["seven_day_fable"]}"#.utf8))
        XCTAssertEqual(ClaudeProvider.clearedWindows(from: answer, grantClears: ["five_hour", "seven_day"]), ["seven_day_fable"])
        let silent = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"result":"reset"}"#.utf8))
        XCTAssertEqual(ClaudeProvider.clearedWindows(from: silent, grantClears: ["five_hour", "seven_day"]), ["five_hour", "seven_day"])
    }

    func testTheLedgerKeepsRecentClaimsOnly() {
        let defaults = UserDefaults(suiteName: "TeamQuotaClaimTests-\(UUID().uuidString)")!
        ResetClaimLedger.record(claim(at: -24 * 9), defaults: defaults, now: now)
        ResetClaimLedger.record(claim(at: -1), defaults: defaults, now: now)
        XCTAssertEqual(ResetClaimLedger.claims(defaults: defaults, now: now).map(\.at), [now.addingTimeInterval(-hour)])
    }
}
