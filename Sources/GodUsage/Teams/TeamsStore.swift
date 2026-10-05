import Foundation
import Observation

/// Teams: the signed-in account, the user's teams, a pending invite, and this Mac's usage upload.
/// Everything is off until the user signs in; uploads start once they are in at least one team.
@MainActor
@Observable
final class TeamsStore {
    struct PendingInvite: Equatable {
        var code: String
        /// Loaded once signed in. Nil while signed out or loading.
        var preview: InvitePreview?
    }

    private(set) var session: TeamsSession?
    private(set) var teams: [TeamSummary] = []
    private(set) var details: [String: TeamDetail] = [:]
    private(set) var pendingInvite: PendingInvite?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastUploadAt: Date?
    private(set) var uploadError: String?
    /// The latest stats per team/range/sort, so a reopened leaderboard shows instantly while it reloads.
    private(set) var cachedStats: [StatsKey: TeamStats] = [:]
    private(set) var statsError: String?
    /// The team the popover and the Teams window show. Falls back to the first team.
    var selectedTeamID: String? {
        get { teams.contains { $0.id == storedSelectedTeamID } ? storedSelectedTeamID : teams.first?.id }
        set {
            storedSelectedTeamID = newValue
            UserDefaults.standard.set(newValue, forKey: Self.selectedTeamKey)
        }
    }
    private var storedSelectedTeamID: String? = UserDefaults.standard.string(forKey: TeamsStore.selectedTeamKey)
    private static let selectedTeamKey = "godusage.teams.selectedTeam.v1"

    struct StatsKey: Hashable {
        var teamID: String
        var range: StatsRange
        var sort: StatsSort
    }

    var user: TeamsUser? { session?.user }
    var isSignedIn: Bool { session != nil }

    @ObservationIgnored private let api: any TeamsAPI
    @ObservationIgnored private let sessionStore: any TeamsSessionStoring
    @ObservationIgnored private let signInProvider: any AppleSignInProviding
    @ObservationIgnored private let historySources: @MainActor () -> [TeamHistorySource]
    @ObservationIgnored private let deviceID: @MainActor () -> String?
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let uploadDebounce: Duration
    @ObservationIgnored private let minimumUploadInterval: TimeInterval
    @ObservationIgnored private var uploadTask: Task<Void, Never>?

    init(
        api: any TeamsAPI = TeamsAPIClient(),
        sessionStore: any TeamsSessionStoring = TeamsSessionFileStore(),
        signInProvider: any AppleSignInProviding = AppleWebSignIn(),
        historySources: @escaping @MainActor () -> [TeamHistorySource],
        deviceID: @escaping @MainActor () -> String?,
        deviceName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        now: @escaping @Sendable () -> Date = { Date() },
        uploadDebounce: Duration = .seconds(5),
        minimumUploadInterval: TimeInterval = 15 * 60
    ) {
        self.api = api
        self.sessionStore = sessionStore
        self.signInProvider = signInProvider
        self.historySources = historySources
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.now = now
        self.uploadDebounce = uploadDebounce
        self.minimumUploadInterval = minimumUploadInterval
        do {
            session = try sessionStore.load()
        } catch {
            AppLog.error(.teams, "couldn't read the saved teams session: \(error)")
            errorMessage = "GodUsage couldn’t read your saved teams sign-in. Sign in again."
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Account

    /// Loads the account and team list. Called when a teams surface opens and at launch.
    func refresh() async {
        guard let token = session?.token else { return }
        await perform {
            async let user = api.me(token: token)
            async let teams = api.teams(token: token)
            let (loadedUser, loadedTeams) = try await (user, teams)
            setUser(loadedUser)
            self.teams = loadedTeams
            details = details.filter { id, _ in loadedTeams.contains { $0.id == id } }
        }
        await loadPendingInvitePreview()
        scheduleUpload()
    }

    func signIn() async {
        let result: AppleSignInResult
        do {
            result = try await signInProvider.signIn()
        } catch AppleSignInError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await perform {
            let session = try await api.exchangeAppleSignIn(code: result.code, codeVerifier: result.codeVerifier)
            try saveSession(session)
            AppLog.info(.teams, "signed in to teams")
        }
        await refresh()
        scheduleUpload(force: true)
    }

    /// Removes this Mac's usage from the server, then ends the session. Other Macs on the same
    /// account keep sharing until they sign out too.
    func signOut() async {
        guard let token = session?.token else { return }
        await perform {
            if let deviceID = deviceID() {
                try await api.deleteDevice(token: token, deviceID: deviceID)
            }
            try await api.signOut(token: token)
            clearSession()
            AppLog.info(.teams, "signed out of teams")
        }
    }

    func rename(to displayName: String) async {
        guard let token = session?.token else { return }
        await perform {
            setUser(try await api.rename(token: token, displayName: displayName))
        }
    }

    /// Deletes the account, its usage on every Mac, and the teams it owns.
    func deleteAccount() async {
        guard let token = session?.token else { return }
        await perform {
            try await api.deleteAccount(token: token)
            clearSession()
            AppLog.info(.teams, "teams account deleted")
        }
    }

    // MARK: - Teams

    func loadTeam(_ id: String) async {
        guard let token = session?.token else { return }
        await perform { store(try await api.team(token: token, id: id)) }
    }

    @discardableResult
    func createTeam(named name: String) async -> TeamDetail? {
        guard let token = session?.token else { return nil }
        var created: TeamDetail?
        await perform {
            let team = try await api.createTeam(token: token, name: name)
            store(team)
            created = team
        }
        if created != nil { scheduleUpload(force: true) }
        return created
    }

    func renameTeam(_ id: String, to name: String) async {
        guard let token = session?.token else { return }
        await perform { store(try await api.updateTeam(token: token, id: id, name: name, publicBoard: nil)) }
    }

    func setPublicBoard(_ id: String, shared: Bool) async {
        guard let token = session?.token else { return }
        await perform { store(try await api.updateTeam(token: token, id: id, name: nil, publicBoard: shared)) }
    }

    func rotateInvite(_ id: String) async {
        guard let token = session?.token else { return }
        await perform { store(try await api.rotateInvite(token: token, teamID: id)) }
    }

    func removeMember(_ userID: String, from teamID: String) async {
        guard let token = session?.token else { return }
        await perform {
            try await api.removeMember(token: token, teamID: teamID, userID: userID)
            store(try await api.team(token: token, id: teamID))
        }
    }

    func leaveTeam(_ id: String) async {
        guard let token = session?.token, let userID = user?.id else { return }
        await perform {
            try await api.removeMember(token: token, teamID: id, userID: userID)
            forget(id)
        }
    }

    func deleteTeam(_ id: String) async {
        guard let token = session?.token else { return }
        await perform {
            try await api.deleteTeam(token: token, id: id)
            forget(id)
        }
    }

    /// Reloads one leaderboard into `cachedStats`. Errors land in `statsError`; the cached value stays.
    func loadStats(teamID: String, range: StatsRange, sort: StatsSort) async {
        do {
            cachedStats[StatsKey(teamID: teamID, range: range, sort: sort)] = try await stats(for: teamID, range: range, sort: sort)
            statsError = nil
        } catch {
            statsError = error.localizedDescription
        }
    }

    func stats(for teamID: String, range: StatsRange, sort: StatsSort) async throws -> TeamStats {
        guard let token = session?.token else { throw TeamsAPIError(kind: .unauthorized, message: "Sign in to see team stats.") }
        let today = DailyUsageAccumulator.dayKey(from: now(), calendar: .current)
        do {
            return try await api.stats(token: token, teamID: teamID, range: range, sort: sort, today: today).stats
        } catch let error as TeamsAPIError where error.kind == .unauthorized {
            sessionExpired()
            throw error
        }
    }

    // MARK: - Invites

    /// Takes an invite from a link the app was opened with, or one the user pasted. Returns false
    /// when the text holds no invite code.
    @discardableResult
    func receiveInvite(_ text: String) async -> Bool {
        guard let code = TeamInviteLink.code(fromText: text) else { return false }
        pendingInvite = PendingInvite(code: code)
        AppLog.info(.teams, "received a team invite")
        await loadPendingInvitePreview()
        return true
    }

    func acceptPendingInvite() async {
        guard let token = session?.token, let invite = pendingInvite else { return }
        var joined = false
        await perform {
            store(try await api.acceptInvite(token: token, code: invite.code))
            pendingInvite = nil
            joined = true
        }
        if joined { scheduleUpload(force: true) }
    }

    func dismissPendingInvite() {
        pendingInvite = nil
    }

    private func loadPendingInvitePreview() async {
        guard let token = session?.token, let invite = pendingInvite, invite.preview == nil else { return }
        await perform {
            let preview = try await api.invite(token: token, code: invite.code)
            if pendingInvite?.code == invite.code { pendingInvite?.preview = preview }
        } onNotFound: { [weak self] in
            self?.pendingInvite = nil
        }
    }

    // MARK: - Upload

    /// Debounced; at most one upload per `minimumUploadInterval` unless `force` (sign-in, joining
    /// or creating a team), so a refresh storm costs one request.
    func scheduleUpload(force: Bool = false) {
        guard session != nil, !teams.isEmpty || force else { return }
        if !force, let lastUploadAt, now().timeIntervalSince(lastUploadAt) < minimumUploadInterval { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self, uploadDebounce] in
            try? await Task.sleep(for: uploadDebounce)
            guard !Task.isCancelled else { return }
            await self?.uploadNow()
        }
    }

    func uploadNow() async {
        guard let token = session?.token else { return }
        guard let deviceID = deviceID() else {
            AppLog.warn(.teams, "teams upload skipped: this Mac's device identity is unresolved")
            uploadError = "This Mac’s identity isn’t resolved yet, so its usage isn’t shared. See iCloud Sync in General settings."
            return
        }
        let upload = TeamUsageUpload.make(
            sources: historySources(),
            deviceName: deviceName,
            dayKeys: UsageHistoryWindow.dayKeys(through: now())
        )
        do {
            try await api.uploadUsage(token: token, deviceID: deviceID, upload: upload)
            lastUploadAt = now()
            uploadError = nil
            AppLog.info(.teams, "teams usage uploaded (\(upload.providers.count) providers)")
        } catch let error as TeamsAPIError where error.kind == .unauthorized {
            sessionExpired()
        } catch {
            uploadError = error.localizedDescription
            AppLog.error(.teams, "teams usage upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func perform(_ operation: () async throws -> Void, onNotFound: (() -> Void)? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch let error as TeamsAPIError where error.kind == .unauthorized {
            sessionExpired()
        } catch let error as TeamsAPIError where error.kind == .notFound && onNotFound != nil {
            onNotFound?()
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func store(_ team: TeamDetail) {
        details[team.id] = team
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            teams[index] = team.summary
        } else {
            teams.append(team.summary)
            teams.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func forget(_ teamID: String) {
        details[teamID] = nil
        teams.removeAll { $0.id == teamID }
    }

    private func setUser(_ user: TeamsUser) {
        guard var session, session.user != user else { return }
        session.user = user
        do { try saveSession(session) } catch {
            AppLog.error(.teams, "couldn't save the teams session: \(error)")
        }
    }

    private func saveSession(_ session: TeamsSession) throws {
        do {
            try sessionStore.save(session)
        } catch {
            AppLog.error(.teams, "couldn't save the teams session: \(error)")
            throw TeamsAPIError(kind: .server, message: "GodUsage couldn’t save your sign-in on this Mac.")
        }
        self.session = session
    }

    private func clearSession() {
        uploadTask?.cancel()
        session = nil
        teams = []
        details = [:]
        lastUploadAt = nil
        uploadError = nil
        cachedStats = [:]
        statsError = nil
        do { try sessionStore.save(nil) } catch {
            AppLog.error(.teams, "couldn't remove the saved teams session: \(error)")
        }
    }

    private func sessionExpired() {
        AppLog.warn(.teams, "teams session is no longer valid; signed out")
        clearSession()
        errorMessage = "Your teams sign-in ended. Sign in again."
    }
}
