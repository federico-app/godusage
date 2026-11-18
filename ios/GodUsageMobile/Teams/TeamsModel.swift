import Foundation
import Observation
import UIKit
import os

/// The app's data: the session from QR pairing, the user's own usage from the server, their teams,
/// and each team's board, plans, and extras (momentum, champions, Today's and this month's boards). A 401 from any call ends the session (the Mac unlinked this device, or
/// the account was deleted).
@MainActor
@Observable
final class TeamsModel {
    private(set) var session: TeamsSession?
    private(set) var myUsage: MyUsage?
    private(set) var teams: [TeamSummary] = []
    private(set) var boards: [String: TeamBoard] = [:]
    /// Each team's plans, by team id, for This Week's Limit.
    private(set) var plans: [String: TeamPlans] = [:]
    /// Who spends fast right now, by team id, then user id.
    private(set) var momentum: [String: [String: TeamMomentum]] = [:]
    /// Each team's champions, newest month first.
    private(set) var champions: [String: [TeamChampion]] = [:]
    /// Each team's Today board (for today's top spender) and Month to Date board (for the projection).
    private(set) var todayBoards: [String: TeamBoard] = [:]
    private(set) var monthBoards: [String: TeamBoard] = [:]
    /// Each plan's last Live Pace state today, so the color doesn't flicker at a threshold.
    var paceMemory: [String: PaceMemory] = [:]
    /// The team the Team tab shows; kept across launches.
    var selectedTeamID: String? {
        didSet { UserDefaults.standard.set(selectedTeamID, forKey: Self.selectedTeamKey) }
    }
    private(set) var isLoading = false
    private(set) var isPairing = false
    var errorMessage: String?

    var isSignedIn: Bool { session != nil }

    private let api = TeamsAPI()
    /// Sample data for screenshots (DEBUG only): no network.
    var isFixture = false
    private static let selectedTeamKey = "godusage.mobile.selectedTeamID"
    private let log = Logger(subsystem: "com.montinovo.godusage.mobile", category: "teams")

    init() {
        selectedTeamID = UserDefaults.standard.string(forKey: Self.selectedTeamKey)
        do {
            session = try TeamsSessionKeychain.load()
        } catch {
            log.error("couldn't read the saved session: \(String(describing: error), privacy: .public)")
            errorMessage = String(localized: "GodUsage couldn’t read your saved sign-in. Link this device again from your Mac.")
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
        guard !isFixture, let token = session?.token, !isLoading else { return }
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
            if !loadedTeams.contains(where: { $0.id == selectedTeamID }) { selectedTeamID = loadedTeams.first?.id }
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    /// Loads a board with Today's and this month's boards for the crown and the projection: in the
    /// same request for the current periods, in a second one for Yesterday.
    func loadBoard(teamID: String, range: BoardRange) async {
        guard !isFixture, let token = session?.token else { return }
        do {
            let today = TeamsFormat.localToday()
            let include = range == .yesterday ? [] : (range == .today ? ["mtd"] : ["today", "mtd"])
            let response = try await api.stats(token: token, teamID: teamID, range: range, today: range.lastDay(), include: include)
            apply(response, teamID: teamID)
            boards[Self.key(teamID, range)] = response.stats
            if range == .today { todayBoards[teamID] = response.stats }
            if range == .yesterday {
                let current = try await api.stats(token: token, teamID: teamID, range: .today, today: today, include: ["mtd"])
                apply(current, teamID: teamID)
                todayBoards[teamID] = current.stats
            }
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    private func apply(_ response: TeamStatsResponse, teamID: String) {
        momentum[teamID] = response.momentum
        if !response.champions.isEmpty { champions[teamID] = response.champions }
        if let today = response.extra["today"] { todayBoards[teamID] = today }
        if let month = response.extra["mtd"] { monthBoards[teamID] = month }
    }

    func loadPlans(teamID: String) async {
        guard !isFixture, let token = session?.token else { return }
        do {
            plans[teamID] = try await api.plans(
                token: token, teamID: teamID, today: TeamsFormat.localToday(), timeZone: TimeZone.current.identifier
            )
            errorMessage = nil
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
        if error is CancellationError { return }
        if let failure = error as? TeamsAPI.Failure, failure.kind == .unauthorized {
            log.warning("teams session ended")
            clear()
            errorMessage = String(localized: "This device was unlinked. Scan a new code from your Mac to link it again.")
            return
        }
        errorMessage = error.localizedDescription
    }

    private func clear() {
        session = nil
        myUsage = nil
        teams = []
        boards = [:]
        plans = [:]
        momentum = [:]
        champions = [:]
        todayBoards = [:]
        monthBoards = [:]
        paceMemory = [:]
        do { try TeamsSessionKeychain.save(nil) } catch {
            log.error("couldn't remove the saved session: \(String(describing: error), privacy: .public)")
        }
    }

    #if DEBUG
    /// Fills the model with sample data for screenshots and previews.
    func loadFixture(session: TeamsSession, usage: MyUsage, teams: [TeamSummary], board: TeamStatsResponse, range: BoardRange, plans: TeamPlans) {
        isFixture = true
        errorMessage = nil
        self.session = session
        myUsage = usage
        self.teams = teams
        selectedTeamID = teams.first?.id
        guard let teamID = teams.first?.id else { return }
        apply(board, teamID: teamID)
        boards[Self.key(teamID, range)] = board.stats
        if range == .today { todayBoards[teamID] = board.stats }
        self.plans[teamID] = plans
    }
    #endif

    private static func key(_ teamID: String, _ range: BoardRange) -> String { "\(teamID)|\(range.rawValue)" }
}
