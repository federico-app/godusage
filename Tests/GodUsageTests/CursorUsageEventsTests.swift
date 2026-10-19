import Foundation
import XCTest
@testable import GodUsage

final class CursorUsageEventsParserTests: XCTestCase {
    func testParsesTokenBucketsTimestampsAndRejectedEvents() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "totalUsageEventsCount": 5,
            "usageEventsDisplay": [
                [
                    "timestamp": "1800000000123",
                    "model": "  composer-1 \n",
                    "tokenUsage": [
                        "inputTokens": 11,
                        "outputTokens": 17,
                        "cacheWriteTokens": 13,
                        "cacheReadTokens": 19
                    ]
                ],
                [
                    "timestamp": 1_800_000_001_234 as NSNumber,
                    "model": " \n"
                ],
                ["timestamp": "not-a-date", "model": "composer-3"],
                [
                    "timestamp": "1800000000123",
                    "model": "composer-4",
                    "tokenUsage": ["inputTokens": -1]
                ],
                [
                    "timestamp": "1800000000123",
                    "model": "composer-5",
                    "tokenUsage": ["outputTokens": 1.5]
                ]
            ]
        ])

        let page = try CursorUsageEvents.parsePage(data)

        XCTAssertEqual(page.totalCount, 5)
        XCTAssertEqual(page.rejectedEventCount, 3)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events[0].model, "composer-1")
        XCTAssertEqual(page.events[0].tokens, TokenBreakdown(input: 11, cacheWrite5m: 13, cacheRead: 19, output: 17))
        XCTAssertEqual(page.events[0].date, Date(timeIntervalSince1970: 1_800_000_000.123))
        XCTAssertEqual(page.events[1].model, "")
        XCTAssertEqual(page.events[1].tokens, TokenBreakdown())
        XCTAssertEqual(page.events[1].date, Date(timeIntervalSince1970: 1_800_000_001.234))
    }

    func testRequiresValidPageShapeAndTotalCount() throws {
        let missingTotal = try JSONSerialization.data(withJSONObject: ["usageEventsDisplay": []])
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(missingTotal)) { error in
            XCTAssertEqual(error as? CursorUsageEventsError, .invalidResponse)
        }
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? CursorUsageEventsError, .invalidResponse)
        }
    }
}

final class CursorUsageEventsClientTests: XCTestCase {
    // Pin the request contract: endpoint, POST body with epoch-ms strings and paging, session
    // cookie, and the same-site Origin.
    func testFetchUsageEventsPageBuildsPOSTRequest() async throws {
        let accessToken = makeHistoryCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }

        let response = try await CursorUsageClient(http: http).fetchUsageEventsPage(
            accessToken: accessToken,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            page: 3,
            pageSize: 1000
        )

        XCTAssertEqual(response?.statusCode, 200)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CursorUsageClient.usageEventsURL)
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Origin"], "https://cursor.com")
        XCTAssertEqual(request.timeout, 15)
        let body = try XCTUnwrap(request.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["startDate"] as? String, "1000000")
        XCTAssertEqual(payload["endDate"] as? String, "2000000")
        XCTAssertEqual((payload["page"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((payload["pageSize"] as? NSNumber)?.intValue, 1000)
    }

    func testNoSessionSkipsTheRequest() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }

        let result = try await CursorUsageClient(http: http).fetchUsageEventsPage(
            accessToken: makeHistoryCursorJWT(sub: nil),
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            page: 1,
            pageSize: 1000
        )

        XCTAssertNil(result)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
