import XCTest
@testable import GodUsage

/// Codex auto-review is free from 2026-10-06 00:00 UTC. Earlier requests keep their dated paid
/// estimates, and the `codex-auto-review` row stays visible either way.
final class CodexAutoReviewPricingTests: XCTestCase {
    private let autoReview = "codex-auto-review"

    /// One request: 100k input (40k cached) + 10k output. At Luna rates that is
    /// 60k x $0.20 + 40k x $0.02 + 10k x $1.20 per million = $0.0248.
    private func parsedEvents(
        timestamp: String = "2026-10-06T08:01:00Z", model: String = "codex-auto-review"
    ) -> [CodexLogUsageScanner.Event] {
        let lines = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: model),
            CodexLogFixture.tokenCount(
                timestamp: timestamp,
                last: CodexLogFixture.usage(input: 100_000, cached: 40_000, output: 10_000)
            )
        ].joined(separator: "\n")
        return CodexLogUsageScanner.parseFile(Data(lines.utf8))
    }

    func testHistoricalAutoReviewKeepsDatedPaidEstimatesAndMeasuredTokens() throws {
        for (timestamp, expectedCost) in [
            ("2026-03-10T08:01:00Z", 0.31),
            ("2026-08-20T08:01:00Z", 0.0248),
            ("2026-10-05T23:59:59Z", 0.0248)
        ] {
            let scan = CodexLogUsageScanner.aggregate(
                events: parsedEvents(timestamp: timestamp), since: .distantPast, pricing: TestPricing.bundled
            )
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000, timestamp)
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001, timestamp)
            let entry = try XCTUnwrap(scan.modelUsage?.daily.first?.models.first)
            XCTAssertEqual(entry.model, autoReview)
            XCTAssertEqual(entry.totalTokens, 110_000)
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        }
    }

    func testFreePricingBeginsAtInclusiveUTCBoundaryWithoutCatalogRates() throws {
        XCTAssertEqual(CodexUsagePricing.autoReviewFreeSince, GodUsageISO8601.date(from: "2026-10-06T00:00:00Z"))
        for timestamp in ["2026-10-06T00:00:00Z", "2026-10-06T00:00:01Z", "2026-10-07T08:01:00Z"] {
            for pricing in [TestPricing.bundled, .empty] {
                let scan = CodexLogUsageScanner.aggregate(
                    events: parsedEvents(timestamp: timestamp), since: .distantPast, pricing: pricing
                )
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 110_000)
                XCTAssertEqual(scan.series.daily.first?.costUSD, 0)
                XCTAssertEqual(
                    scan.modelUsage?.daily.first?.models,
                    [ModelUsageEntry(model: autoReview, totalTokens: 110_000, costUSD: 0)]
                )
                XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
            }
        }
    }

    func testOffsetTimestampsUseUTCInstant() throws {
        for (timestamp, expectedCost) in [
            ("2026-10-06T02:59:59+03:00", 0.0248),
            ("2026-10-05T17:00:00-07:00", 0.0)
        ] {
            let scan = CodexLogUsageScanner.aggregate(
                events: parsedEvents(timestamp: timestamp), since: .distantPast, pricing: TestPricing.bundled
            )
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expectedCost, accuracy: 0.000_001, timestamp)
        }
    }

    func testMissingHistoricalRatesStayUnknownBeforeTheBoundary() throws {
        let event = try XCTUnwrap(parsedEvents(timestamp: "2026-10-05T23:59:59Z").first)
        let scan = CodexLogUsageScanner.aggregate(events: [event], since: .distantPast, pricing: .empty)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: event.timestamp)], [autoReview])
    }

    func testPaidAndFreeRequestsInOneScanDoNotShareRates() throws {
        // Same model and tier on both sides of the cutoff: a pricing cache keyed by slug alone
        // would price the second request with the first one's rates.
        for order in [["2026-10-05T23:59:59Z", "2026-10-06T00:00:00Z"], ["2026-10-06T00:00:00Z", "2026-10-05T23:59:59Z"]] {
            for fast in [false, true] {
                let events = order.flatMap { parsedEvents(timestamp: $0) }.map { event -> CodexLogUsageScanner.Event in
                    var event = event
                    event.isFast = fast
                    return event
                }
                let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
                let total = scan.series.daily.compactMap(\.costUSD).reduce(0, +)
                XCTAssertEqual(total, 0.0248 * (fast ? 2 : 1), accuracy: 0.000_001)
                XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 220_000)
            }
        }
    }

    func testFreeAutoReviewStaysSeparateFromPaidLuna() throws {
        let events = parsedEvents() + parsedEvents(model: "gpt-5.6-luna")
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        let day = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(day.totalTokens, 220_000)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.0248, accuracy: 0.000_001)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(models.first(where: { $0.model == autoReview })?.costUSD, 0)
        XCTAssertEqual(try XCTUnwrap(models.first(where: { $0.model == "gpt-5.6-luna" })?.costUSD), 0.0248, accuracy: 0.000_001)
    }

    func testSharedPricingEntryPointsUseTheRequestTime() throws {
        let tokens = TokenBreakdown(input: 60_000, cacheRead: 40_000, output: 10_000)
        for (timestamp, expectedCost) in [("2026-10-05T23:59:59Z", 0.0248), ("2026-10-06T00:00:00Z", 0.0)] {
            let date = try XCTUnwrap(GodUsageISO8601.date(from: timestamp))
            let cost = CodexUsagePricing.estimatedCost(pricing: TestPricing.bundled, model: autoReview, tokens: tokens, at: date)
            XCTAssertEqual(try XCTUnwrap(cost), expectedCost, accuracy: 0.000_001)
            let emptyCost = CodexUsagePricing.estimatedCost(pricing: .empty, model: autoReview, tokens: tokens, at: date)
            XCTAssertEqual(emptyCost, expectedCost == 0 ? 0 : nil)
        }
    }

    func testMixedPaidAndFreeAutoReviewStaysNamedBelowTheSpendThreshold() throws {
        let paid = parsedEvents(timestamp: "2026-10-05T08:01:00Z")
        let free = parsedEvents(timestamp: "2026-10-06T00:00:00Z") + parsedEvents(timestamp: "2026-10-06T08:01:00Z")
        let now = try XCTUnwrap(free.last?.timestamp)
        // Astra costs $1.14; historical auto-review and ordinary Luna each cost $0.0248, under 5%.
        let events = paid + free + parsedEvents(model: "gpt-6-astra") + parsedEvents(model: "gpt-5.6-luna")
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: now, modelUsage: scan.modelUsage, modelSourceNote: "From Codex test logs"
        )
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == "Last 30 Days" }) else {
            return XCTFail("Expected a Last 30 Days spend row")
        }
        let detail = try XCTUnwrap(breakdown)
        XCTAssertEqual(detail.models.map(\.model), ["gpt-6-astra", autoReview, ModelUsageEntry.otherModelName])
        let review = try XCTUnwrap(detail.models.first(where: { $0.model == autoReview }))
        XCTAssertEqual(review.totalTokens, 330_000)
        let other = try XCTUnwrap(detail.models.first(where: { $0.model == ModelUsageEntry.otherModelName }))
        XCTAssertEqual(other.variants?.map(\.model), ["gpt-5.6-luna"])
    }

    func testFreeAutoReviewOnlyPeriodStillShowsItsRow() throws {
        let events = parsedEvents()
        let now = try XCTUnwrap(events.first?.timestamp)
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: now, modelUsage: scan.modelUsage, modelSourceNote: "From Codex test logs"
        )
        guard case .values(_, _, _, _, let unknown, let breakdown) = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("Expected a Today spend row")
        }
        XCTAssertTrue(unknown.isEmpty)
        let models = try XCTUnwrap(breakdown).models
        XCTAssertEqual(models.map(\.model), [autoReview])
        XCTAssertEqual(models.first?.costUSD, 0)
    }
}
