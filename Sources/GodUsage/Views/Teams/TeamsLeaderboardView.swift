import Charts
import SwiftUI

/// The Teams window: pick a team, a range, and spend or tokens; see the ranking and who uses what.
struct TeamsLeaderboardView: View {
    @Environment(AppContainer.self) private var container
    @AppStorage("godusage.teams.window.range") private var range: StatsRange = .week
    @AppStorage("godusage.teams.window.sort") private var sort: StatsSort = .cost
    @State private var stats: TeamStats?
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        let teams = container.teams
        VStack(spacing: 0) {
            if let invite = teams.pendingInvite {
                inviteBanner(invite)
            }
            if !teams.isSignedIn {
                emptyState(
                    title: "Compare AI Usage With Friends",
                    message: "Sign in with Apple, then create a team or open an invite link."
                ) { TeamsSignInButton(teams: teams).frame(width: 240) }
            } else if teams.teams.isEmpty {
                emptyState(title: "No Teams Yet", message: "Create a team or join one with an invite link.") {
                    Button("Open Teams Settings…") { SettingsWindowLink.open(pane: .teams) }
                }
            } else {
                toolbar
                Divider()
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.traySurface)
        .task { await teams.refresh() }
        .task(id: LoadKey(teamID: currentTeamID, range: range, sort: sort, teamCount: teams.teams.count)) {
            await load()
        }
    }

    private struct LoadKey: Hashable {
        var teamID: String?
        var range: StatsRange
        var sort: StatsSort
        var teamCount: Int
    }

    /// Shared with the popover's Team screen and the Teams settings pane.
    private var currentTeamID: String? { container.teams.selectedTeamID }

    private func load() async {
        guard let teamID = currentTeamID else {
            stats = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            stats = try await container.teams.stats(for: teamID, range: range, sort: sort)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Team", selection: Binding(get: { currentTeamID ?? "" }, set: { container.teams.selectedTeamID = $0 })) {
                ForEach(container.teams.teams) { team in
                    Text(team.name).tag(team.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Picker("Range", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Metric", selection: $sort) {
                ForEach(StatsSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                Task {
                    await container.teams.uploadNow()
                    await load()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError, stats == nil {
            emptyState(title: "Couldn't Load the Leaderboard", message: loadError) {
                Button("Try Again") { Task { await load() } }
            }
        } else if let stats {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(Theme.notice)
                    }
                    summary(stats)
                    TeamsRankingList(stats: stats, sort: sort, currentUserID: container.teams.user?.id, providerName: providerName)
                    TeamsCharts(stats: stats, sort: sort, providerName: providerName)
                }
                .padding(16)
            }
        } else {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    private func summary(_ stats: TeamStats) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TeamsFormat.value(stats.totals, sort: sort))
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                Text(rangeCaption(stats))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func rangeCaption(_ stats: TeamStats) -> String {
        let total = sort == .cost ? "Total spend" : "Total tokens"
        guard stats.range.from != stats.range.to else { return "\(total) · \(TeamsFormat.dayLabel(stats.range.to))" }
        return "\(total) · \(TeamsFormat.dayLabel(stats.range.from)) – \(TeamsFormat.dayLabel(stats.range.to))"
    }

    private func providerName(_ id: String) -> String {
        container.registry.providers.first { $0.id == id }?.displayName ?? id.capitalized
    }

    private func inviteBanner(_ invite: TeamsStore.PendingInvite) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill").foregroundStyle(.secondary)
            if let preview = invite.preview, !preview.alreadyMember {
                Text("You're invited to join **\(preview.team.name)**.")
                Spacer()
                Button("Not Now") { container.teams.dismissPendingInvite() }
                Button("Join Team") { Task { await container.teams.acceptPendingInvite() } }
                    .keyboardShortcut(.defaultAction)
            } else if invite.preview?.alreadyMember == true {
                Text("You're already in \(invite.preview?.team.name ?? "this team").")
                Spacer()
                Button("OK") { container.teams.dismissPendingInvite() }
            } else if container.teams.isSignedIn {
                Text("Loading invitation…")
                Spacer()
            } else {
                Text("Sign in to join the team you were invited to.")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.secondary.opacity(0.08))
    }

    private func emptyState(title: String, message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.3")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action().padding(.top, 6)
            if let error = container.teams.errorMessage {
                Text(error).font(.caption).foregroundStyle(Theme.notice).frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// The ranked member list.
private struct TeamsRankingList: View {
    let stats: TeamStats
    let sort: StatsSort
    let currentUserID: String?
    let providerName: (String) -> String

    var body: some View {
        let top = stats.members.map { $0.totals.value(for: sort) }.max() ?? 0
        VStack(spacing: 0) {
            ForEach(Array(stats.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider() }
                HStack(alignment: .center, spacing: 10) {
                    Text("\(member.rank)")
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(member.rank <= 3 ? .primary : .secondary)
                        .frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(member.displayName).lineLimit(1)
                            if member.userID == currentUserID {
                                Text("You")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        ProviderSplitBar(providers: member.providers, top: top, sort: sort, height: 6)
                    }
                    Text(TeamsFormat.value(member.totals, sort: sort))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .cardSurface()
    }
}
