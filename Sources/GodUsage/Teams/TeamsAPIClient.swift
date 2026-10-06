import Foundation

/// A teams backend failure with a message that is safe to show as-is.
struct TeamsAPIError: Error, LocalizedError, Equatable {
    enum Kind: Equatable {
        /// The session is gone (expired, signed out elsewhere, account deleted). Sign in again.
        case unauthorized
        case notFound
        case conflict
        case invalidRequest
        case server
        case network
    }

    var kind: Kind
    var message: String

    var errorDescription: String? { message }
}

protocol TeamsAPI: Sendable {
    /// Trades the web sign-in's one-time code (and its PKCE verifier) for a session.
    func exchangeAppleSignIn(code: String, codeVerifier: String) async throws -> TeamsSession
    func signOut(token: String) async throws
    func me(token: String) async throws -> TeamsUser
    func rename(token: String, displayName: String) async throws -> TeamsUser
    func deleteAccount(token: String) async throws
    /// Everything the server keeps about the account, as JSON.
    func exportData(token: String) async throws -> Data
    func teams(token: String) async throws -> [TeamSummary]
    func team(token: String, id: String) async throws -> TeamDetail
    func createTeam(token: String, name: String) async throws -> TeamDetail
    func updateTeam(token: String, id: String, name: String?, publicBoard: Bool?) async throws -> TeamDetail
    func deleteTeam(token: String, id: String) async throws
    func rotateInvite(token: String, teamID: String) async throws -> TeamDetail
    func removeMember(token: String, teamID: String, userID: String) async throws
    func setMemberRole(token: String, teamID: String, userID: String, role: TeamRole) async throws -> TeamDetail
    func invite(token: String, code: String) async throws -> InvitePreview
    func acceptInvite(token: String, code: String) async throws -> TeamDetail
    func stats(token: String, teamID: String, range: StatsRange, sort: StatsSort, today: String) async throws -> TeamStatsResponse
    func uploadUsage(token: String, deviceID: String, upload: TeamUsageUpload) async throws
    func setReaction(token: String, teamID: String, userID: String, reaction: TeamReaction, on: Bool) async throws -> TeamReactions
    func challenges(token: String, teamID: String, today: String) async throws -> [TeamChallenge]
    func createChallenge(token: String, teamID: String, kind: ChallengeKind, days: Int, today: String) async throws -> TeamChallenge
    func deleteChallenge(token: String, teamID: String, challengeID: String) async throws
    func deleteDevice(token: String, deviceID: String) async throws
    func plans(token: String, teamID: String, today: String) async throws -> TeamPlansReport
    func savePlans(token: String, teamID: String, plans: [TeamPlan], today: String) async throws -> TeamPlansReport
}

/// The teams backend over HTTPS. Dev builds (`….dev` bundle id) talk to the dev Worker, which has
/// its own database and accepts only dev-build sign-ins, so testing never touches real teams.
struct TeamsAPIClient: TeamsAPI {
    static let productionBaseURL = URL(string: "https://godusage-api.federico-c80.workers.dev")!
    static let developmentBaseURL = URL(string: "https://godusage-api-dev.federico-c80.workers.dev")!
    /// `defaults write <bundle id> godusage.teams.apiBaseURL http://127.0.0.1:8787` points a build at
    /// `wrangler dev`.
    static let baseURLOverrideKey = "godusage.teams.apiBaseURL"

    static func defaultBaseURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier, defaults: UserDefaults = .standard) -> URL {
        if let override = defaults.string(forKey: baseURLOverrideKey), let url = URL(string: override), url.scheme != nil {
            return url
        }
        return AppChannel.isDev(bundleIdentifier: bundleIdentifier) ? developmentBaseURL : productionBaseURL
    }

    let baseURL: URL
    let http: any HTTPClient

    init(baseURL: URL = TeamsAPIClient.defaultBaseURL(), http: any HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    func exchangeAppleSignIn(code: String, codeVerifier: String) async throws -> TeamsSession {
        struct Body: Encodable { var code: String; var codeVerifier: String }
        return try await send("POST", "/v1/auth/apple/exchange", body: Body(code: code, codeVerifier: codeVerifier))
    }

    func signOut(token: String) async throws {
        try await sendEmpty("POST", "/v1/auth/logout", token: token)
    }

    func me(token: String) async throws -> TeamsUser {
        let response: UserEnvelope = try await send("GET", "/v1/me", token: token)
        return response.user
    }

    func rename(token: String, displayName: String) async throws -> TeamsUser {
        struct Body: Encodable { var displayName: String }
        let response: UserEnvelope = try await send("PATCH", "/v1/me", token: token, body: Body(displayName: displayName))
        return response.user
    }

    func deleteAccount(token: String) async throws {
        try await sendEmpty("DELETE", "/v1/me", token: token)
    }

    func exportData(token: String) async throws -> Data {
        try await perform("GET", "/v1/me/export", token: token, body: NoBody?.none).body
    }

    /// The service's privacy policy and terms, linked from the sign-in.
    var privacyURL: URL { baseURL.appendingPathComponent("privacy") }
    var termsURL: URL { baseURL.appendingPathComponent("terms") }

    func teams(token: String) async throws -> [TeamSummary] {
        struct Envelope: Decodable { var teams: [TeamSummary] }
        let response: Envelope = try await send("GET", "/v1/teams", token: token)
        return response.teams
    }

    func team(token: String, id: String) async throws -> TeamDetail {
        let response: TeamEnvelope = try await send("GET", "/v1/teams/\(escaped(id))", token: token)
        return response.team
    }

    func createTeam(token: String, name: String) async throws -> TeamDetail {
        struct Body: Encodable { var name: String }
        let response: TeamEnvelope = try await send("POST", "/v1/teams", token: token, body: Body(name: name))
        return response.team
    }

    func updateTeam(token: String, id: String, name: String?, publicBoard: Bool?) async throws -> TeamDetail {
        struct Body: Encodable { var name: String?; var publicBoard: Bool? }
        let response: TeamEnvelope = try await send(
            "PATCH", "/v1/teams/\(escaped(id))", token: token, body: Body(name: name, publicBoard: publicBoard)
        )
        return response.team
    }

    func deleteTeam(token: String, id: String) async throws {
        try await sendEmpty("DELETE", "/v1/teams/\(escaped(id))", token: token)
    }

    func rotateInvite(token: String, teamID: String) async throws -> TeamDetail {
        let response: TeamEnvelope = try await send("POST", "/v1/teams/\(escaped(teamID))/invite", token: token)
        return response.team
    }

    func removeMember(token: String, teamID: String, userID: String) async throws {
        try await sendEmpty("DELETE", "/v1/teams/\(escaped(teamID))/members/\(escaped(userID))", token: token)
    }

    func setMemberRole(token: String, teamID: String, userID: String, role: TeamRole) async throws -> TeamDetail {
        struct Body: Encodable { var role: TeamRole }
        let response: TeamEnvelope = try await send(
            "PATCH", "/v1/teams/\(escaped(teamID))/members/\(escaped(userID))", token: token, body: Body(role: role)
        )
        return response.team
    }

    func invite(token: String, code: String) async throws -> InvitePreview {
        try await send("GET", "/v1/invites/\(escaped(code))", token: token)
    }

    func acceptInvite(token: String, code: String) async throws -> TeamDetail {
        let response: TeamEnvelope = try await send("POST", "/v1/invites/\(escaped(code))/accept", token: token)
        return response.team
    }

    func stats(token: String, teamID: String, range: StatsRange, sort: StatsSort, today: String) async throws -> TeamStatsResponse {
        let query = "range=\(range.rawValue)&sort=\(sort.rawValue)&today=\(escaped(today))"
        return try await send("GET", "/v1/teams/\(escaped(teamID))/stats?\(query)", token: token)
    }

    func uploadUsage(token: String, deviceID: String, upload: TeamUsageUpload) async throws {
        try await sendEmpty("PUT", "/v1/devices/\(escaped(deviceID))/usage", token: token, body: upload)
    }

    func setReaction(token: String, teamID: String, userID: String, reaction: TeamReaction, on: Bool) async throws -> TeamReactions {
        struct Envelope: Decodable { var week: String; var reactions: [String: MemberReactions] }
        let path = "/v1/teams/\(escaped(teamID))/members/\(escaped(userID))/reactions/\(reaction.rawValue)"
        let response: Envelope = try await send(on ? "PUT" : "DELETE", path, token: token)
        return TeamReactions(week: response.week, byMember: response.reactions)
    }

    func challenges(token: String, teamID: String, today: String) async throws -> [TeamChallenge] {
        struct Envelope: Decodable { var challenges: [TeamChallenge] }
        let response: Envelope = try await send("GET", "/v1/teams/\(escaped(teamID))/challenges?today=\(escaped(today))", token: token)
        return response.challenges
    }

    func createChallenge(token: String, teamID: String, kind: ChallengeKind, days: Int, today: String) async throws -> TeamChallenge {
        struct Body: Encodable { var kind: ChallengeKind; var days: Int; var today: String }
        struct Envelope: Decodable { var challenge: TeamChallenge }
        let response: Envelope = try await send(
            "POST", "/v1/teams/\(escaped(teamID))/challenges", token: token, body: Body(kind: kind, days: days, today: today)
        )
        return response.challenge
    }

    func deleteChallenge(token: String, teamID: String, challengeID: String) async throws {
        try await sendEmpty("DELETE", "/v1/teams/\(escaped(teamID))/challenges/\(escaped(challengeID))", token: token)
    }

    func deleteDevice(token: String, deviceID: String) async throws {
        do {
            try await sendEmpty("DELETE", "/v1/devices/\(escaped(deviceID))", token: token)
        } catch let error as TeamsAPIError where error.kind == .notFound {
            // This Mac never uploaded, so there is nothing to remove.
        }
    }

    func plans(token: String, teamID: String, today: String) async throws -> TeamPlansReport {
        try await send("GET", "/v1/teams/\(escaped(teamID))/plans?today=\(escaped(today))", token: token)
    }

    func savePlans(token: String, teamID: String, plans: [TeamPlan], today: String) async throws -> TeamPlansReport {
        struct Body: Encodable { var plans: [TeamPlan] }
        return try await send("PUT", "/v1/teams/\(escaped(teamID))/plans?today=\(escaped(today))", token: token, body: Body(plans: plans))
    }

    // MARK: - Transport

    private struct UserEnvelope: Decodable { var user: TeamsUser }
    private struct TeamEnvelope: Decodable { var team: TeamDetail }
    private struct NoBody: Encodable {}
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#"))) ?? component
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, token: String? = nil, body: (some Encodable)? = NoBody?.none
    ) async throws -> Response {
        let response = try await perform(method, path, token: token, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            AppLog.error(.teams, "\(method) \(pathWithoutQuery(path)) returned an unreadable response: \(error)")
            throw TeamsAPIError(kind: .server, message: "The teams server sent a response GodUsage couldn’t read. Update GodUsage and try again.")
        }
    }

    private func sendEmpty(_ method: String, _ path: String, token: String? = nil, body: (some Encodable)? = NoBody?.none) async throws {
        _ = try await perform(method, path, token: token, body: body)
    }

    private func perform(_ method: String, _ path: String, token: String?, body: (some Encodable)?) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw TeamsAPIError(kind: .invalidRequest, message: "Invalid teams request.")
        }
        var headers = ["accept": "application/json"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        var data: Data?
        if let body {
            headers["content-type"] = "application/json"
            data = try JSONEncoder().encode(body)
        }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(method: method, url: url, headers: headers, body: data, timeout: 20))
        } catch {
            AppLog.warn(.teams, "\(method) \(pathWithoutQuery(path)) failed: \(error.localizedDescription)")
            throw TeamsAPIError(kind: .network, message: "Couldn’t reach the teams server. Check your connection and try again.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(from: response, method: method, path: pathWithoutQuery(path))
        }
        return response
    }

    private static func error(from response: HTTPResponse, method: String, path: String) -> TeamsAPIError {
        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error.message
        AppLog.warn(.teams, "\(method) \(path) -> \(response.statusCode)")
        let kind: TeamsAPIError.Kind = switch response.statusCode {
        case 401: .unauthorized
        case 404: .notFound
        case 409: .conflict
        case 400, 403, 405, 413: .invalidRequest
        default: .server
        }
        let fallback = kind == .server
            ? "The teams server had a problem (HTTP \(response.statusCode)). Try again later."
            : "The teams request failed (HTTP \(response.statusCode))."
        return TeamsAPIError(kind: kind, message: message ?? fallback)
    }

    private func pathWithoutQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1).first ?? Substring(path))
    }
}
