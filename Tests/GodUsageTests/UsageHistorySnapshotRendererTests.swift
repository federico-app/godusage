import XCTest
@testable import GodUsage

final class UsageHistoryAggregatorTests: XCTestCase {
    func testRendererReplacesOnlySpendRowsAndKeepsLocalState() throws {
        let local = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Max",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 1, kind: .dollars)]),
                .badge(label: "Local notice", text: "Keep me", colorHex: "#123456")
            ],
            refreshedAt: Date(timeIntervalSince1970: 500),
            warning: "Local warning"
        )
        let history = history(tokens: 350, cost: 3, model: "Opus")

        let rendered = UsageHistorySnapshotRenderer.render(
            local: local,
            history: history,
            descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "From logs"),
            now: localDay(2026, 7, 13)
        )

        XCTAssertEqual(rendered.plan, "Max")
        XCTAssertEqual(rendered.warning, "Local warning")
        XCTAssertEqual(rendered.refreshedAt, local.refreshedAt)
        XCTAssertEqual(rendered.line(label: "Session"), local.line(label: "Session"))
        XCTAssertEqual(rendered.line(label: "Local notice"), local.line(label: "Local notice"))
        guard case .values(_, let values, _, _, _, let breakdown) = rendered.line(label: "Today") else {
            return XCTFail("Today should be rebuilt as a values row")
        }
        XCTAssertEqual(values.map(\.number), [3, 350])
        XCTAssertEqual(breakdown?.totalTokens, 350)
        XCTAssertEqual(breakdown?.models.map(\.model), ["Opus"])
        XCTAssertTrue(rendered.lines.contains { $0.label == "Usage Trend" })
    }

    private func history(
        tokens: Int,
        cost: Double?,
        model: String,
        unknown: Set<String> = []
    ) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-13", totalTokens: tokens, costUSD: cost)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-07-13", models: [
                    ModelUsageEntry(model: model, totalTokens: tokens, costUSD: cost)
                ])
            ]),
            unknownModelsByDay: unknown.isEmpty ? [:] : ["2026-07-13": unknown]
        )
    }

    private func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
