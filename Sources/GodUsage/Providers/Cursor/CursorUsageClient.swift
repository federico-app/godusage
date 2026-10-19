import Foundation

struct CursorSession: Equatable, Sendable {
    var userID: String
    var sessionToken: String
}

struct CursorUsageClient: Sendable {
    static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let grokBotUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    static let restUsageURL = URL(string: "https://cursor.com/api/usage")!
    static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!
    static let usageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.usageURL, accessToken: accessToken)
    }

    func fetchGrokBotUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.grokBotUsageURL, accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.planURL, accessToken: accessToken)
    }

    func fetchCredits(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.creditsURL, accessToken: accessToken)
    }

    func fetchRequestBasedUsage(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        var components = URLComponents(url: Self.restUsageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
        guard let url = components?.url else { return nil }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    func fetchUsageSummary(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageSummaryURL,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    func fetchStripeBalance(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.stripeURL,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    /// POST one page of the dashboard's usage events for `[start, end]` (epoch-ms strings, `end`
    /// inclusive) using the same `WorkosCursorSessionToken` cookie as the Stripe/REST calls, plus the
    /// same-site `Origin` the dashboard sends. 1,000 is the largest page Cursor accepts. Returns
    /// nil when the access token carries no usable session.
    func fetchUsageEventsPage(
        accessToken: String,
        start: Date,
        end: Date,
        page: Int,
        pageSize: Int
    ) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        let body: [String: Any] = [
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(end.timeIntervalSince1970 * 1000)),
            "page": page,
            "pageSize": pageSize
        ]

        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.usageEventsURL,
            headers: [
                "Cookie": "WorkosCursorSessionToken=\(session.sessionToken)",
                "Content-Type": "application/json",
                "Origin": "https://cursor.com"
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    private func connectPost(_ url: URL, accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: Data("{}".utf8),
            timeout: 10
        ))
    }

    static func session(from accessToken: String) -> CursorSession? {
        guard let subject = CursorAuthStore.tokenSubject(accessToken) else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return CursorSession(userID: userID, sessionToken: "\(userID)%3A%3A\(accessToken)")
    }
}
