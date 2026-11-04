import XCTest
@testable import GodUsage

final class TeamQuotaLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_201_600) // 2026-10-05 12:00 UTC
    private let hour: TimeInterval = 3_600

    private func reading(_ percent: Double, endsIn hours: Double, observedAgo: Double = 0, provider: String = "claude") -> TeamQuotaReading {
        TeamQuotaReading(
            provider: provider, cardID: provider, accountKey: nil,
            endsAt: now.addingTimeInterval(hours * hour), periodHours: 168,
            percent: percent, observedAt: now.addingTimeInterval(-observedAgo * hour)
        )
    }

    private func record(_ log: inout TeamQuotaLog, _ readings: [TeamQuotaReading], at date: Date? = nil) {
        log.record(readings, perDeviceKey: { _ in "acct" }, now: date ?? now)
    }

    func testReadsTheLimitingWindowOfEachProvider() throws {
        let resetsAt = now.addingTimeInterval(48 * hour)
        let snapshot = ProviderSnapshot(
            providerID: "claude@ab12cd34",
            displayName: "Claude",
            lines: [
                .progress(label: "Session", used: 90, limit: 100, format: .percent, resetsAt: now, periodDurationMs: 18_000_000),
                .progress(label: "Weekly", used: 42, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: 604_800_000),
            ],
            refreshedAt: now
        )
        let claude = try XCTUnwrap(TeamQuotaReading.make(cardID: "claude@ab12cd34", snapshot: snapshot, accountKey: nil))
        XCTAssertEqual(claude.provider, "claude")
        XCTAssertEqual(claude.percent, 42)
        XCTAssertEqual(claude.periodHours, 168)
        XCTAssertEqual(claude.endsAt, resetsAt)

        let cursor = ProviderSnapshot(
            providerID: "cursor", displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 15, limit: 20, format: .dollars, resetsAt: resetsAt, periodDurationMs: 2_592_000_000)],
            refreshedAt: now
        )
        XCTAssertEqual(TeamQuotaReading.make(cardID: "cursor", snapshot: cursor, accountKey: "k")?.percent, 75)
        XCTAssertNil(TeamQuotaReading.make(cardID: "grok", snapshot: snapshot, accountKey: nil), "only Claude, Codex, and Cursor plans")
    }

    func testKeepsTheHighestShareOfAWindowAcrossReadingsThatNameItsResetSlightlyDifferently() throws {
        var log = TeamQuotaLog()
        record(&log, [reading(30, endsIn: 50)])
        record(&log, [reading(55, endsIn: 50.4)])
        record(&log, [reading(20, endsIn: 49.8, observedAgo: 5)])
        XCTAssertEqual(log.windows.count, 1)
        let window = try XCTUnwrap(log.windows.first)
        XCTAssertEqual(window.percent, 55)
        XCTAssertEqual(window.observedAt, now)
    }

    func testANewWindowBeforeTheResetClosesTheOldOneNow() {
        var log = TeamQuotaLog()
        record(&log, [reading(70, endsIn: 50, observedAgo: 1)])
        // A claimed reset: the provider now reports a fresh week.
        record(&log, [reading(2, endsIn: 168)])
        XCTAssertEqual(log.windows.map(\.percent), [70, 2])
        XCTAssertEqual(log.windows.first?.endsAt, now)
    }

    func testDropsWindowsOlderThanTheUploadWindowAndSendsHourlyReadings() throws {
        var log = TeamQuotaLog()
        record(&log, [reading(10, endsIn: -41 * 24), reading(66.66, endsIn: 20, observedAgo: 0.5)])
        let wire = log.wire
        XCTAssertEqual(wire.count, 1)
        let window = try XCTUnwrap(wire.first)
        XCTAssertEqual(window.percent, 66.7)
        XCTAssertEqual(window.endsAt, "2026-10-06T08:00:00Z")
        XCTAssertEqual(window.observedAt, "2026-10-05T11:00:00Z")
        XCTAssertEqual(window.account, "acct")
        XCTAssertEqual(window.kind, "limit")
    }

    func testReadsTheSessionInUseButNotAnIdleOne() throws {
        let snapshot = { (used: Double) in
            ProviderSnapshot(
                providerID: "codex", displayName: "Codex",
                lines: [
                    .progress(label: "Session", used: used, limit: 100, format: .percent, resetsAt: self.now, periodDurationMs: 18_000_000),
                    .progress(label: "Weekly", used: 10, limit: 100, format: .percent, resetsAt: self.now, periodDurationMs: 604_800_000),
                ],
                refreshedAt: self.now
            )
        }
        let readings = TeamQuotaReading.readings(cardID: "codex", snapshot: snapshot(35), accountKey: nil)
        XCTAssertEqual(readings.map(\.kind), [.limit, .session])
        XCTAssertEqual(readings.last?.periodHours, 5)
        XCTAssertEqual(readings.last?.percent, 35)
        // An idle session names a reset counted from now: logging it would add an empty session per pass.
        XCTAssertEqual(TeamQuotaReading.readings(cardID: "codex", snapshot: snapshot(0), accountKey: nil).map(\.kind), [.limit])
    }

    func testKeepsTheShareSeenAtTheEndOfEachLocalDayOfAWeeklyWindow() throws {
        var log = TeamQuotaLog()
        let dayKey = { (date: Date) in DailyUsageAccumulator.dayKey(from: date, calendar: self.utc) }
        log.record([reading(10, endsIn: 100, observedAgo: 30)], perDeviceKey: { _ in "acct" }, now: now, dayKey: dayKey)
        log.record([reading(14, endsIn: 100, observedAgo: 26)], perDeviceKey: { _ in "acct" }, now: now, dayKey: dayKey)
        log.record([reading(22, endsIn: 100)], perDeviceKey: { _ in "acct" }, now: now, dayKey: dayKey)
        // A session of the same account is its own window and keeps no days.
        var session = reading(60, endsIn: 3)
        session.kind = .session
        session.periodHours = 5
        log.record([session], perDeviceKey: { _ in "acct" }, now: now, dayKey: dayKey)

        let wire = log.wire
        XCTAssertEqual(wire.map(\.kind), ["limit", "session"])
        XCTAssertEqual(wire.first?.days, [TeamQuotaLog.Day(day: "2026-10-04", percent: 14), TeamQuotaLog.Day(day: "2026-10-05", percent: 22)])
        XCTAssertNil(wire.last?.days)
        XCTAssertEqual(wire.last?.percent, 60)
    }

    func testReadsALogSavedBeforeSessionsAndDays() throws {
        let saved = #"{"windows":[{"provider":"claude","account":"acct","endsAt":800000000,"periodHours":168,"percent":40,"observedAt":799990000}]}"#
        let log = try JSONDecoder().decode(TeamQuotaLog.self, from: Data(saved.utf8))
        XCTAssertEqual(log.windows.first?.kind, .limit)
        XCTAssertEqual(log.windows.first?.days, [])
    }

    func testMovesACardsWindowsToItsAccountOnceTheAccountIsKnown() throws {
        var log = TeamQuotaLog()
        record(&log, [reading(30, endsIn: 50, observedAgo: 2)])
        XCTAssertEqual(log.wire.first?.perDevice, true)
        var identified = reading(35, endsIn: 50)
        identified.accountKey = "account"
        record(&log, [identified])
        XCTAssertEqual(log.windows.count, 1)
        let window = try XCTUnwrap(log.wire.first)
        XCTAssertEqual(window.account, "account")
        XCTAssertEqual(window.percent, 35)
        XCTAssertNil(window.perDevice)
    }

    func testNamesAClaudeAccountByAccountAndOrgAndACodexOneByUserAndAccount() {
        let personal = ClaudeAccountIdentity(accountUUID: "ACC-1", organizationUUID: "org-a", email: "a@example.com")
        XCTAssertEqual(
            TeamQuotaAccount.claude(personal),
            TeamQuotaAccount.claude(ClaudeAccountIdentity(accountUUID: "acc-1", organizationUUID: "ORG-A", email: nil)),
            "the same account on another Mac, whatever the case or email"
        )
        XCTAssertNotEqual(TeamQuotaAccount.claude(personal), TeamQuotaAccount.claude(ClaudeAccountIdentity(accountUUID: "acc-1", organizationUUID: "org-b")))
        XCTAssertNil(TeamQuotaAccount.claude(nil))

        func idToken(user: String) -> String {
            let claims = #"{"sub":"auth0|x","https://api.openai.com/auth":{"chatgpt_user_id":"\#(user)"}}"#
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(payload).sig"
        }
        let bea = TeamQuotaAccount.codex(CodexTokens(idToken: idToken(user: "user-bea"), accountID: "workspace"))
        XCTAssertNotNil(bea)
        XCTAssertEqual(bea, TeamQuotaAccount.codex(CodexTokens(idToken: idToken(user: "user-bea"), accountID: "workspace")))
        // Two members of one Team workspace share its account id, but not their user.
        XCTAssertNotEqual(bea, TeamQuotaAccount.codex(CodexTokens(idToken: idToken(user: "user-cy"), accountID: "workspace")))
        XCTAssertNil(TeamQuotaAccount.codex(CodexTokens(accountID: "workspace")))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
