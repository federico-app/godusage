import XCTest
@testable import GodUsage

final class ClaudeRateLimitDiagnosticsTests: XCTestCase {
    func testDiagnosticsListRetryAfterRateLimitHeadersAndBody() {
        let response = HTTPResponse(
            statusCode: 429,
            headers: [
                "retry-after": "3540",
                "anthropic-ratelimit-unified-status": "rejected",
                "request-id": "req_123",
                "set-cookie": "session=secret",
                "content-type": "application/json"
            ],
            body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#.utf8)
        )

        let line = ClaudeUsageMapper.rateLimitDiagnostics(response, retryAfterSeconds: 3540)

        XCTAssertTrue(line.hasPrefix("retry-after 3540s; "))
        XCTAssertTrue(line.contains("anthropic-ratelimit-unified-status=rejected, request-id=req_123, retry-after=3540"))
        XCTAssertTrue(line.contains("rate_limit_error"))
        XCTAssertFalse(line.contains("secret"))
        XCTAssertFalse(line.contains("content-type"))
    }

    func testDiagnosticsWithoutRetryAfterOrBody() {
        let response = HTTPResponse(statusCode: 429, headers: [:], body: Data())

        XCTAssertEqual(
            ClaudeUsageMapper.rateLimitDiagnostics(response, retryAfterSeconds: nil),
            "retry-after none (default cooldown); headers: none"
        )
    }

    func testWarningNamesWhenTheShownValuesWereFetched() {
        let now = GodUsageISO8601.date(from: "2026-11-19T11:40:00.000Z")!
        let fetched = now.addingTimeInterval(-50 * 60)
        let fetchedText = ClaudeUsageMapper.formatValuesFrom(fetched, now: now)

        let warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: 1500, valuesFrom: fetched, now: now)

        XCTAssertEqual(
            warning,
            "Updates blocked by Anthropic. Showing values from \(fetchedText). Be patient — manual refreshes will make it worse. Retrying in ~25m."
        )
    }

    func testValuesFromAddsTheDateWhenNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = GodUsageISO8601.date(from: "2026-11-19T11:40:00.000Z")!
        let yesterday = GodUsageISO8601.date(from: "2026-11-18T17:46:00.000Z")!

        XCTAssertEqual(
            ClaudeUsageMapper.formatValuesFrom(now, now: now, calendar: calendar),
            now.formatted(date: .omitted, time: .shortened)
        )
        XCTAssertEqual(
            ClaudeUsageMapper.formatValuesFrom(yesterday, now: now, calendar: calendar),
            yesterday.formatted(date: .abbreviated, time: .shortened)
        )
    }
}
