import Foundation
import XCTest
@testable import GodUsage

@MainActor
final class CursorUsageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let userID = "cursor-history-user"
    private let token = makeHistoryCursorJWT(sub: "google-oauth2|cursor-history-user")
    private var timeZone: String { Calendar.current.timeZone.identifier }

    func testBackfillPublishesThirtyDaysOfSpendAndWritesTheCache() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            let event = CursorHistoryTestData.event(on: params.start, model: "composer-1", input: 10_000)
            return try CursorHistoryTestData.page(total: 1, events: params.page == 1 ? [event] : [])
        }
        let provider = makeProvider(http: http, store: store, now: now)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        XCTAssertEqual(snapshot.usageHistory?.series.daily.count, 30)
        XCTAssertEqual(snapshot.usageHistory?.accountKey, TeamAccountKey.make(provider: "cursor", accountID: userID))
        XCTAssertEqual(
            Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
            Set(dayStarts.map(\.key))
        )

        let dailyCost = try XCTUnwrap(TestPricing.bundled.estimatedCostDollars(
            model: "composer-1",
            tokens: TokenBreakdown(input: 10_000),
            applyLongContextRates: false
        ))
        let expectedThirtyDayCost = ((dailyCost * 100).rounded() / 100) * 30
        XCTAssertEqual(
            try XCTUnwrap(values(snapshot.lines, "Last 30 Days")?.first?.number),
            expectedThirtyDayCost,
            accuracy: 0.000_001
        )
        let savedDays = store.load(userID: userID, timeZone: timeZone)
        XCTAssertEqual(savedDays.count, 30)
        XCTAssertFalse(try XCTUnwrap(savedDays[dayStarts[0].key]).isComplete, "today is still running")
        XCTAssertTrue(try XCTUnwrap(savedDays[dayStarts[1].key]).isComplete)
    }

    func testIncrementalRefreshOnlyRequestsTodayAndYesterday() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        store.save(cachedHistory(now: now), userID: userID, timeZone: timeZone)
        let http = historyHTTP { request in
            guard CursorHistoryTestData.parameters(request) != nil else {
                return CursorHistoryTestData.invalidRequest
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
                       Set(dayStarts(now: now).prefix(2).map(\.key)))
        XCTAssertEqual(history?.count, 30)
        let unchangedOlderDay = try XCTUnwrap(history?.first { $0.dayStart == dayStarts(now: now)[2].start })
        XCTAssertEqual(unchangedOlderDay.day.models["composer-1"]?.input, 2_002)
    }

    func testRefetchesIncompleteOlderDayAndStoresFinalizedTotals() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let incompleteDay = dayStarts[5]
        var cachedDays = cachedHistory(now: now)
        cachedDays[incompleteDay.key] = CursorUsageDay(models: ["composer-1": TokenBreakdown(input: 100)], isComplete: false)
        store.save(cachedDays, userID: userID, timeZone: timeZone)
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            guard params.startKey == incompleteDay.key else {
                return try CursorHistoryTestData.page(total: 0, events: [])
            }
            let event = CursorHistoryTestData.event(on: params.start, model: "composer-1", input: 900)
            return try CursorHistoryTestData.page(total: 1, events: params.page == 1 ? [event] : [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(
            Set(http.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey }),
            Set([dayStarts[0].key, dayStarts[1].key, incompleteDay.key])
        )
        let publishedDay = try XCTUnwrap(history?.first { $0.dayStart == incompleteDay.start })
        XCTAssertEqual(publishedDay.day.models["composer-1"]?.input, 900)
        XCTAssertTrue(publishedDay.day.isComplete)
        let savedDay = try XCTUnwrap(store.load(userID: userID, timeZone: timeZone)[incompleteDay.key])
        XCTAssertEqual(savedDay, publishedDay.day)
    }

    /// Regression: a short download (pages that stop before Cursor's total) must not replace the
    /// stored day with its partial sum.
    func testShortPagesKeepPreviouslyStoredDay() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let days = dayStarts(now: now)
        let todayKey = days[0].key
        var cachedDays = cachedHistory(now: now)
        cachedDays[todayKey] = CursorUsageDay(models: ["composer-1": TokenBreakdown(input: 2_000)], isComplete: false)
        store.save(cachedDays, userID: userID, timeZone: timeZone)
        let pageOneEvents = (0..<1000).map { _ in
            CursorHistoryTestData.event(on: days[0].start, model: "composer-1", input: 1)
        }
        let http = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            if params.startKey == todayKey {
                return try CursorHistoryTestData.page(total: 1500, events: params.page == 1 ? pageOneEvents : [])
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let fetcher = makeFetcher(http: http, store: store)

        let history = await fetcher.refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(http.requests.filter { CursorHistoryTestData.parameters($0)?.startKey == todayKey }.count, 2)
        XCTAssertEqual(history?.count, 30)
        XCTAssertEqual(history?.first?.day.models["composer-1"]?.input, 2_000)
        let savedToday = store.load(userID: userID, timeZone: timeZone)[todayKey]
        XCTAssertEqual(savedToday?.models["composer-1"]?.input, 2_000)
    }

    /// Regression: a backfill that runs out of budget keeps the days it finished, publishes nothing
    /// (so the dashboard keeps its last-good chart), and the next refresh only fetches what's missing.
    func testDeadlineKeepsFinishedDaysAndNextRefreshResumesBackfill() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let nowStart = Calendar.current.startOfDay(for: now)
        let slowHTTP = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            let age = Calendar.current.dateComponents([.day], from: params.start, to: nowStart).day ?? 0
            if age > 10 {
                try await Task.sleep(for: .seconds(5))
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }
        let provider = makeProvider(http: slowHTTP, store: store, now: now, budget: 0.3)

        let clock = ContinuousClock()
        let started = clock.now
        let firstSnapshot = await provider.refresh()
        let elapsed = started.duration(to: clock.now)
        let persistedAfterDeadline = store.load(userID: userID, timeZone: timeZone)
        XCTAssertTrue(firstSnapshot.lines.contains { $0.label == "Total usage" }, "live plan usage must survive")
        XCTAssertNil(firstSnapshot.usageHistory)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertGreaterThan(persistedAfterDeadline.count, 0)
        XCTAssertLessThan(persistedAfterDeadline.count, 30)

        let fastHTTP = historyHTTP { _ in try CursorHistoryTestData.page(total: 0, events: []) }
        let secondProvider = makeProvider(http: fastHTTP, store: store, now: now, budget: 2)
        let secondSnapshot = await secondProvider.refresh()
        let requestedKeys = Set(fastHTTP.requests.compactMap { CursorHistoryTestData.parameters($0)?.startKey })
        let allDays = dayStarts(now: now)
        let expectedKeys = Set(allDays.enumerated().filter { index, day in
            index < 2 || persistedAfterDeadline[day.key] == nil
        }.map(\.element.key))

        XCTAssertEqual(requestedKeys, expectedKeys)
        XCTAssertNotNil(secondSnapshot.usageHistory)
        XCTAssertEqual(secondSnapshot.usageHistory?.series.daily.count, 0)
    }

    func testAccountCacheIsolation() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        store.save(cachedHistory(now: now), userID: "account-a", timeZone: timeZone)
        let http = historyHTTP { _ in try CursorHistoryTestData.page(total: 0, events: []) }
        let fetcher = makeFetcher(http: http, store: store)

        let result = await fetcher.refresh(
            accessToken: makeHistoryCursorJWT(sub: "google-oauth2|account-b"),
            userID: "account-b",
            now: now
        )

        XCTAssertEqual(http.requests.count, 30)
        XCTAssertEqual(result?.count, 30)
        XCTAssertEqual(store.load(userID: "account-a", timeZone: timeZone), cachedHistory(now: now))
        XCTAssertEqual(store.load(userID: "account-b", timeZone: timeZone).count, 30)
    }

    func testTimeZoneChangeIgnoresStoredDays() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(cachedHistory(now: now), userID: userID, timeZone: "Europe/Rome")

        XCTAssertTrue(store.load(userID: userID, timeZone: "America/New_York").isEmpty)
        XCTAssertEqual(store.load(userID: userID, timeZone: "Europe/Rome").count, 30)
    }

    func testHTTPFailureLeavesMissingDayUnstoredAndKeepsExistingFileUnchanged() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = self.now
        let dayStarts = dayStarts(now: now)
        let todayKey = dayStarts[0].key
        let missingDayHTTP = historyHTTP { request in
            guard let params = CursorHistoryTestData.parameters(request) else {
                return CursorHistoryTestData.invalidRequest
            }
            if params.startKey == todayKey {
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            return try CursorHistoryTestData.page(total: 0, events: [])
        }

        let incomplete = await makeFetcher(http: missingDayHTTP, store: store)
            .refresh(accessToken: token, userID: userID, now: now)

        XCTAssertNil(incomplete)
        let partial = store.load(userID: userID, timeZone: timeZone)
        XCTAssertNil(partial[todayKey])
        XCTAssertEqual(partial.count, 29)

        store.save(cachedHistory(now: now), userID: userID, timeZone: timeZone)
        let fileURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let originalFile = try Data(contentsOf: fileURL)
        let failedRefreshHTTP = historyHTTP { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }

        let retained = await makeFetcher(http: failedRefreshHTTP, store: store)
            .refresh(accessToken: token, userID: userID, now: now)

        XCTAssertEqual(retained?.count, 30)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalFile)
    }

    private func makeStore() -> (CursorUsageHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-history-tests-\(UUID().uuidString)", isDirectory: true)
        return (CursorUsageHistoryStore(directory: directory), directory)
    }

    private func makeProvider(
        http: RoutingHTTPClient,
        store: CursorUsageHistoryStore,
        now: Date,
        budget: TimeInterval = 20
    ) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: HistoryCursorSQLite(values: [CursorAuthStore.accessTokenKey: token]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled },
            spendHistoryBudget: budget,
            usageHistoryStore: store
        )
    }

    private func makeFetcher(http: RoutingHTTPClient, store: CursorUsageHistoryStore) -> CursorSpendHistoryFetcher {
        CursorSpendHistoryFetcher(client: CursorUsageClient(http: http), store: store, budget: 20)
    }

    private func historyHTTP(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            if request.url == CursorUsageClient.usageEventsURL {
                return try await handler(request)
            }
            if request.url == CursorUsageClient.usageURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}
                """.utf8))
            }
            if request.url == CursorUsageClient.planURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if request.url == CursorUsageClient.creditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func dayStarts(now: Date) -> [(key: String, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<30).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (DailyUsageAccumulator.dayKey(from: start, calendar: calendar), start)
        }
    }

    private func cachedHistory(now: Date) -> [String: CursorUsageDay] {
        Dictionary(uniqueKeysWithValues: dayStarts(now: now).enumerated().map { index, day in
            (day.key, CursorUsageDay(models: ["composer-1": TokenBreakdown(input: 2_000 + index)], isComplete: true))
        })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

private struct CursorHistoryRequest: Sendable {
    var start: Date
    var startKey: String
    var page: Int
}

private struct CursorHistoryEvent: Sendable {
    var timestampMilliseconds: Int
    var model: String
    var input: Int
}

private enum CursorHistoryTestData {
    static let invalidRequest = HTTPResponse(statusCode: 400, headers: [:], body: Data())

    static func parameters(_ request: HTTPRequest) -> CursorHistoryRequest? {
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let startString = payload["startDate"] as? String,
              let milliseconds = Int(startString),
              let page = (payload["page"] as? NSNumber)?.intValue
        else {
            return nil
        }
        let start = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return CursorHistoryRequest(
            start: start,
            startKey: DailyUsageAccumulator.dayKey(from: start, calendar: .current),
            page: page
        )
    }

    static func event(on dayStart: Date, model: String, input: Int) -> CursorHistoryEvent {
        CursorHistoryEvent(timestampMilliseconds: Int(dayStart.timeIntervalSince1970 * 1000), model: model, input: input)
    }

    static func page(total: Int, events: [CursorHistoryEvent]) throws -> HTTPResponse {
        let response: [String: Any] = [
            "totalUsageEventsCount": total,
            "usageEventsDisplay": events.map { event in
                [
                    "timestamp": String(event.timestampMilliseconds),
                    "model": event.model,
                    "tokenUsage": ["inputTokens": event.input]
                ]
            }
        ]
        return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: response))
    }
}

func makeHistoryCursorJWT(sub: String?) -> String {
    let payload = sub.map { #"{"sub":"\#($0)","exp":9999999999}"# } ?? #"{"exp":9999999999}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class HistoryCursorSQLite: SQLiteAccessing, @unchecked Sendable {
    private let values: [String: String]
    init(values: [String: String]) { self.values = values }

    func queryValue(path: String, sql: String) throws -> String? {
        // The batched read folds matching keys into one JSON object, like sqlite's
        // `json_group_object` does.
        if sql.contains("json_group_object") {
            var object: [String: String] = [:]
            for (key, value) in values where sql.contains("'\(key)'") { object[key] = value }
            guard !object.isEmpty else { return nil }
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}
