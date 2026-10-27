import SwiftUI
import XCTest
@testable import GodUsage

final class TeamModelsOverTimeTests: XCTestCase {
    private func day(_ key: String, _ models: [(String, Double)], other: Double? = nil) -> TeamStats.Day {
        TeamStats.Day(
            day: key, members: [], providers: [],
            models: models.map { TeamStats.DayModel(model: $0.0, provider: "claude", tokens: 1, costUSD: $0.1) },
            otherModels: other.map { UsageTotals(tokens: 1, costUSD: $0) }
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    func testDaysSumIntoWeeksAndMonths() {
        // Sunday 2026-10-04 closes one ISO week; Monday 2026-10-05 opens the next.
        let daily = [
            day("2026-09-30", [("opus", 1)]),
            day("2026-10-04", [("opus", 2), ("sonnet", 1)]),
            day("2026-10-05", [("opus", 4)], other: 0.5),
        ]
        let byDay = TeamModelsOverTimeChart.bars(daily: daily, bucket: .day, calendar: calendar)
        XCTAssertEqual(byDay.count, 3)

        let byWeek = TeamModelsOverTimeChart.bars(daily: daily, bucket: .week, calendar: calendar)
        XCTAssertEqual(byWeek.count, 2)
        XCTAssertEqual(byWeek[0].models.first { $0.name == "opus" }?.totals.costUSD, 3)
        XCTAssertEqual(byWeek[1].models.first { $0.name == TeamModelsOverTimeChart.otherName }?.totals.costUSD, 0.5)

        let byMonth = TeamModelsOverTimeChart.bars(daily: daily, bucket: .month, calendar: calendar)
        XCTAssertEqual(byMonth.count, 2)
        XCTAssertEqual(byMonth[1].models.first { $0.name == "opus" }?.totals.costUSD, 6)
    }

    func testModelsOfOneProviderGetDifferentShades() {
        let colors = TeamModelPalette.colors(for: [("claude", "opus-5-5"), ("codex", "gpt-6"), ("claude", "opus-5"), ("claude", "sonnet-5-5")])
        XCTAssertEqual(colors["claude/opus-5-5"], TotalSpendPalette.color(for: "claude"), "the largest model keeps the brand color")
        XCTAssertEqual(colors["codex/gpt-6"], TotalSpendPalette.color(for: "codex"))
        XCTAssertNotEqual(colors["claude/opus-5"], colors["claude/opus-5-5"])
        XCTAssertNotEqual(colors["claude/sonnet-5-5"], colors["claude/opus-5"])
    }
}
