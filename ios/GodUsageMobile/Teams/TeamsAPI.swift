import Foundation
import os

/// The GodUsage teams backend, read-only from the phone (plus pairing and sign-out). Debug builds
/// talk to the dev server, like the Mac's DEV channel and the dev CloudKit container; Release builds
/// to production. A pairing code names its server, and the app accepts only its own.
struct TeamsAPI: Sendable {
    #if DEV_CHANNEL
    static let baseURL = URL(string: "https://api-dev.godusage.com")!
    #else
    static let baseURL = URL(string: "https://api.godusage.com")!
    #endif

    struct Failure: Error, LocalizedError {
        enum Kind { case unauthorized, notFound, invalid, server, network }
        var kind: Kind
        var message: String
        var errorDescription: String? { message }
    }

    var baseURL: URL = TeamsAPI.baseURL
    private let log = Logger(subsystem: "com.montinovo.godusage.mobile", category: "teams")

    func exchangePairingCode(_ code: String, deviceName: String) async throws -> TeamsSession {
        struct Body: Encodable { var code: String; var deviceName: String }
        return try await send("POST", "/v1/auth/pairing/exchange", body: Body(code: code, deviceName: deviceName))
    }

    func signOut(token: String) async throws {
        _ = try await perform("POST", "/v1/auth/logout", token: token, body: Optional<Empty>.none)
    }

    func me(token: String) async throws -> TeamsUser {
        struct Envelope: Decodable { var user: TeamsUser }
        let envelope: Envelope = try await send("GET", "/v1/me", token: token)
        return envelope.user
    }

    func teams(token: String) async throws -> [TeamSummary] {
        struct Envelope: Decodable { var teams: [TeamSummary] }
        let envelope: Envelope = try await send("GET", "/v1/teams", token: token)
        return envelope.teams
    }

    func myUsage(token: String, today: String) async throws -> MyUsage {
        try await send("GET", "/v1/me/usage?today=\(today)", token: token)
    }

    func stats(token: String, teamID: String, range: BoardRange, today: String) async throws -> TeamBoard {
        struct Envelope: Decodable { var stats: TeamBoard }
        let id = teamID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#"))) ?? teamID
        let envelope: Envelope = try await send("GET", "/v1/teams/\(id)/stats?range=\(range.rawValue)&sort=cost&today=\(today)", token: token)
        return envelope.stats
    }

    // MARK: - Transport

    private struct Empty: Encodable {}
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, token: String? = nil, body: (some Encodable)? = Optional<Empty>.none) async throws -> Response {
        let data = try await perform(method, path, token: token, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            log.error("\(method, privacy: .public) \(path, privacy: .public) returned an unreadable response: \(String(describing: error), privacy: .public)")
            throw Failure(kind: .server, message: "The GodUsage server sent a response this app couldn’t read. Update the app and try again.")
        }
    }

    private func perform(_ method: String, _ path: String, token: String?, body: (some Encodable)?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw Failure(kind: .invalid, message: "Invalid request.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.warning("\(method, privacy: .public) \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw Failure(kind: .network, message: "Couldn’t reach the GodUsage server. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            log.warning("\(method, privacy: .public) \(path, privacy: .public) -> \(status)")
            let kind: Failure.Kind = switch status {
            case 401: .unauthorized
            case 404: .notFound
            case 400, 403, 405, 409, 413: .invalid
            default: .server
            }
            throw Failure(kind: kind, message: message ?? "The GodUsage server had a problem (HTTP \(status)). Try again later.")
        }
        return data
    }
}
