import Foundation

/// Builds Cursor's 30-local-day spend history one day at a time from `get-filtered-usage-events`.
///
/// Every refresh re-fetches today and yesterday (late events still land there) plus every day not yet
/// stored, newest first, a few days at a time, within `budget` seconds. A day is stored only when its
/// pages add up to Cursor's `totalUsageEventsCount`; a day that fails or doesn't finish keeps its
/// stored value. Days finished before the deadline are saved, so the backfill resumes on the next
/// refresh instead of starting over. History is returned only once all 30 days are stored, so a
/// partial backfill never publishes a chart with false zero days.
struct CursorSpendHistoryFetcher: Sendable {
    static let windowDays = 30

    var client: CursorUsageClient
    var store: CursorUsageHistoryStore
    var budget: TimeInterval
    var maxConcurrentDays = 4
    var pageSize = 1000

    private struct DayRequest: Sendable {
        var key: String
        var start: Date
        var end: Date
        var isComplete: Bool
    }

    private enum DayTaskResult: Sendable {
        case success(key: String, day: CursorUsageDay)
        case failure(FailureReason)
        case deadline
    }

    private enum FailureReason: Sendable {
        case http(Int)
        case request
        case invalidResponse
        case incompletePages

        var logText: String {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .request: "request failed"
            case .invalidResponse: "invalid response"
            case .incompletePages: "incomplete pages"
            }
        }
    }

    func refresh(accessToken: String, userID: String, now: Date) async -> [(dayStart: Date, day: CursorUsageDay)]? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let window = (0..<Self.windowDays).compactMap { offset -> DayRequest? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: start)
            else {
                return nil
            }
            let end = min(nextDay, now)
            return DayRequest(
                key: DailyUsageAccumulator.dayKey(from: start, calendar: calendar),
                start: start,
                end: end,
                isComplete: end == nextDay
            )
        }
        let timeZone = calendar.timeZone.identifier
        let windowKeys = Set(window.map(\.key))
        var stored = store.load(userID: userID, timeZone: timeZone).filter { windowKeys.contains($0.key) }
        // `window` is newest first, so today and yesterday lead and the backfill walks backwards.
        let daysToFetch = window.enumerated().compactMap { index, day in
            index < 2 || stored[day.key]?.isComplete != true ? day : nil
        }

        var failures = 0
        var firstFailure: FailureReason?
        var savedDays = 0
        var deadlineHit = false

        await withTaskGroup(of: DayTaskResult.self) { group in
            var nextIndex = 0
            func startNextDay() {
                guard nextIndex < daysToFetch.count else { return }
                let day = daysToFetch[nextIndex]
                nextIndex += 1
                group.addTask { await fetchDay(day, accessToken: accessToken, calendar: calendar) }
            }

            for _ in 0..<min(maxConcurrentDays, daysToFetch.count) { startNextDay() }
            var activeDays = min(maxConcurrentDays, daysToFetch.count)
            guard activeDays > 0 else { return }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return .deadline
            }
            defer { group.cancelAll() }

            while let result = await group.next() {
                switch result {
                case .success(let key, let day):
                    stored[key] = day
                    savedDays += 1
                case .failure(let reason):
                    failures += 1
                    if firstFailure == nil { firstFailure = reason }
                case .deadline:
                    deadlineHit = true
                    return
                }
                activeDays -= 1
                if nextIndex < daysToFetch.count {
                    startNextDay()
                    activeDays += 1
                }
                if activeDays == 0 { return }
            }
        }

        if failures > 0, let firstFailure {
            AppLog.warn(
                LogTag.plugin("cursor"),
                "usage events: \(failures) day\(failures == 1 ? "" : "s") failed (\(firstFailure.logText))"
            )
        }
        if deadlineHit {
            let missing = window.filter { stored[$0.key] == nil }.count
            AppLog.warn(
                LogTag.plugin("cursor"),
                "usage events: \(String(format: "%g", budget))s budget hit with \(missing) of \(window.count) days still missing; resuming next refresh"
            )
        }
        if savedDays > 0 {
            store.save(stored, userID: userID, timeZone: timeZone)
        }
        guard window.allSatisfy({ stored[$0.key] != nil }) else { return nil }
        return window.compactMap { day in
            stored[day.key].map { (dayStart: day.start, day: $0) }
        }
    }

    /// Walks every page of one day. `endDate` is inclusive on Cursor's side, so it stops one
    /// millisecond before the next local midnight.
    private func fetchDay(_ request: DayRequest, accessToken: String, calendar: Calendar) async -> DayTaskResult {
        let end = Date(timeIntervalSince1970: Double(Int(request.end.timeIntervalSince1970 * 1000) - 1) / 1000)
        var page = 1
        var expectedTotal: Int?
        var receivedCount = 0
        var day = CursorUsageDay(models: [:], isComplete: request.isComplete)

        while true {
            let response: HTTPResponse
            do {
                guard let sent = try await client.fetchUsageEventsPage(
                    accessToken: accessToken,
                    start: request.start,
                    end: end,
                    page: page,
                    pageSize: pageSize
                ) else {
                    return .failure(.request)
                }
                response = sent
            } catch {
                return .failure(.request)
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.http(response.statusCode))
            }
            let parsed: CursorUsageEventsPage
            do {
                parsed = try CursorUsageEvents.parsePage(response.body)
            } catch {
                return .failure(.invalidResponse)
            }
            // The total moving between pages means events landed mid-walk; the pages no longer line up.
            if let expectedTotal, parsed.totalCount != expectedTotal {
                return .failure(.incompletePages)
            }
            expectedTotal = parsed.totalCount
            let pageEventCount = parsed.events.count + parsed.rejectedEventCount
            receivedCount += pageEventCount
            if parsed.rejectedEventCount > 0 {
                AppLog.warn(
                    LogTag.plugin("cursor"),
                    "usage events: \(parsed.rejectedEventCount) rejected event\(parsed.rejectedEventCount == 1 ? "" : "s") on one page"
                )
            }
            for event in parsed.events {
                guard DailyUsageAccumulator.dayKey(from: event.date, calendar: calendar) == request.key else {
                    return .failure(.invalidResponse)
                }
                day.add(event.tokens, for: event.model)
            }
            if receivedCount == parsed.totalCount {
                return .success(key: request.key, day: day)
            }
            // An empty page before the total is reached, or more events than promised, can't be trusted.
            if pageEventCount == 0 || receivedCount > parsed.totalCount {
                return .failure(.incompletePages)
            }
            page += 1
        }
    }
}
