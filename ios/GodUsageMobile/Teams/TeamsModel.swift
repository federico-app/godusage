import Foundation
import Observation
import UIKit
import os

/// The Teams tab: the session from QR pairing, the user's own usage from the server, their teams,
/// and each team's board. A 401 from any call ends the session (the Mac unlinked this device, or
/// the account was deleted).
@MainActor
@Observable
final class TeamsModel {
    private(set) var session: TeamsSession?
    private(set) var myUsage: MyUsage?
    private(set) var teams: [TeamSummary] = []
    private(set) var boards: [String: TeamBoard] = [:]
    private(set) var isLoading = false
    private(set) var isPairing = false
    var errorMessage: String?

    var isSignedIn: Bool { session != nil }

    private let api = TeamsAPI()
    private let log = Logger(subsystem: "com.montinovo.godusage.mobile", category: "teams")

    init() {
        do {
            session = try TeamsSessionKeychain.load()
        } catch {
            log.error("couldn't read the saved session: \(String(describing: error), privacy: .public)")
            errorMessage = "GodUsage couldn’t read your saved sign-in. Link this device again from your Mac."
        }
    }

    /// Signs in with a scanned QR code or an opened `godusage://pair` link.
    func pair(with text: String) async {
        isPairing = true
        defer { isPairing = false }
        do {
            let link = try PairingLink.parse(text)
            try link.check(against: TeamsAPI.baseURL)
            let session = try await api.exchangePairingCode(link.code, deviceName: UIDevice.current.name)
            try TeamsSessionKeychain.save(session)
            self.session = session
            errorMessage = nil
            log.info("linked to a teams account")
        } catch {
            log.warning("pairing failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return
        }
        await refresh()
    }

    func refresh() async {
        guard let token = session?.token, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let user = api.me(token: token)
            async let usage = api.myUsage(token: token, today: TeamsFormat.localToday())
            async let teams = api.teams(token: token)
            let (loadedUser, loadedUsage, loadedTeams) = try await (user, usage, teams)
            if loadedUser != session?.user, var updated = session {
                updated.user = loadedUser
                do { try TeamsSessionKeychain.save(updated) } catch {
                    log.error("couldn't save the renamed session: \(String(describing: error), privacy: .public)")
                }
                session = updated
            }
            myUsage = loadedUsage
            self.teams = loadedTeams
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func loadBoard(teamID: String, range: BoardRange) async {
        guard let token = session?.token else { return }
        do {
            boards[Self.key(teamID, range)] = try await api.stats(token: token, teamID: teamID, range: range, today: TeamsFormat.localToday())
        } catch {
            handle(error)
        }
    }

    func board(teamID: String, range: BoardRange) -> TeamBoard? {
        boards[Self.key(teamID, range)]
    }

    func signOut() async {
        if let token = session?.token {
            do { try await api.signOut(token: token) } catch {
                // The local sign-out still happens; the Mac can unlink a session the server kept.
                log.warning("sign-out request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        clear()
    }

    private func handle(_ error: Error) {
        if let failure = error as? TeamsAPI.Failure, failure.kind == .unauthorized {
            log.warning("teams session ended")
            clear()
            errorMessage = "This device was unlinked. Scan a new code from your Mac to link it again."
            return
        }
        errorMessage = error.localizedDescription
    }

    private func clear() {
        session = nil
        myUsage = nil
        teams = []
        boards = [:]
        do { try TeamsSessionKeychain.save(nil) } catch {
            log.error("couldn't remove the saved session: \(String(describing: error), privacy: .public)")
        }
    }

    private static func key(_ teamID: String, _ range: BoardRange) -> String { "\(teamID)|\(range.rawValue)" }
}
