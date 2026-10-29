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
        log.record(readings, account: { _ in "acct" }, now: date ?? now)
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
    }
}
