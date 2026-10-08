import Foundation
import Observation

/// A one-time code from `POST /v1/auth/pairing`. It works once, until `expiresAt`.
struct PairingCode: Decodable, Equatable, Sendable {
    var code: String
    /// ISO 8601, as the server sent it.
    var expiresAt: String
}

/// An iPhone or iPad signed in to this account by QR pairing.
struct LinkedDevice: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// ISO 8601.
    var linkedAt: String
}

/// What the QR code holds: `godusage://pair?code=…&server=https://api.godusage.com`. The phone
/// refuses a code for another server than its own (a DEV code in the production app, or the reverse).
enum DevicePairingLink {
    static func url(code: String, server: URL) -> URL {
        var components = URLComponents()
        components.scheme = "godusage"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "server", value: server.absoluteString),
        ]
        guard let url = components.url else {
            preconditionFailure("DevicePairingLink: couldn't build a URL for \(server)")
        }
        return url
    }
}

/// Linking the GodUsage iPhone app to this account: the QR code on screen, and the phones and
/// iPads already linked. Reads the session from `TeamsStore`; a 401 sends it through
/// `TeamsStore.refresh()`, which signs the Mac out.
@MainActor
@Observable
final class DevicePairingStore {
    struct ActiveCode: Equatable {
        var url: URL
        var expiresAt: Date
    }

    private(set) var linkedDevices: [LinkedDevice] = []
    private(set) var activeCode: ActiveCode?
    /// The device that appeared while the code was on screen. Clears with the next code.
    private(set) var justLinked: LinkedDevice?
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private let teams: TeamsStore
    @ObservationIgnored private let api: any TeamsAPI
    @ObservationIgnored private let server: URL
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollInterval: Duration

    init(
        teams: TeamsStore,
        api: any TeamsAPI = TeamsAPIClient(),
        server: URL = TeamsAPIClient.defaultBaseURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = .seconds(3)
    ) {
        self.teams = teams
        self.api = api
        self.server = server
        self.now = now
        self.pollInterval = pollInterval
    }

    func dismissError() { errorMessage = nil }

    func loadDevices() async {
        await perform { token in
            linkedDevices = try await api.linkedDevices(token: token)
        }
    }

    /// Asks for a fresh code (the previous one stops working) and shows it.
    func showCode() async {
        justLinked = nil
        await perform { token in
            let code = try await api.createPairingCode(token: token)
            guard let expiresAt = Self.date(code.expiresAt) else {
                AppLog.error(.teams, "pairing code has an unreadable expiry: \(code.expiresAt)")
                throw TeamsAPIError(kind: .server, message: "The teams server sent a response GodUsage couldn’t read. Update GodUsage and try again.")
            }
            activeCode = ActiveCode(url: DevicePairingLink.url(code: code.code, server: server), expiresAt: expiresAt)
        }
    }

    func hideCode() {
        activeCode = nil
    }

    /// While a code is on screen, checks for a newly linked device and hides the code once one
    /// appears. Runs until the code is hidden, expires, or the calling task is cancelled.
    func watchForNewDevice() async {
        let known = Set(linkedDevices.map(\.id))
        while let code = activeCode, code.expiresAt > now(), !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard activeCode == code, let token = teams.sessionToken else { return }
            do {
                let devices = try await api.linkedDevices(token: token)
                linkedDevices = devices
                if let added = devices.first(where: { !known.contains($0.id) }) {
                    AppLog.info(.teams, "linked a device by QR pairing")
                    justLinked = added
                    activeCode = nil
                }
            } catch {
                // A missed poll is retried on the next tick; the code stays on screen.
                AppLog.warn(.teams, "linked-devices poll failed: \(error.localizedDescription)")
            }
        }
        if let code = activeCode, code.expiresAt <= now() { activeCode = nil }
    }

    func unlink(_ device: LinkedDevice) async {
        await perform { token in
            do {
                try await api.unlinkDevice(token: token, id: device.id)
            } catch let error as TeamsAPIError where error.kind == .notFound {
                // Already gone (unlinked from another Mac, or the phone signed out).
            }
            linkedDevices.removeAll { $0.id == device.id }
            AppLog.info(.teams, "unlinked a device")
        }
    }

    private func perform(_ operation: (String) async throws -> Void) async {
        guard let token = teams.sessionToken else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(token)
            errorMessage = nil
        } catch let error as TeamsAPIError where error.kind == .unauthorized {
            activeCode = nil
            await teams.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }
}
