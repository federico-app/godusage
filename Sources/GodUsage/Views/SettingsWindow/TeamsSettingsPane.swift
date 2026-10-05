import SwiftUI

/// The Settings window's Teams pane, top to bottom: the account, the team list, the selected
/// team's members and links, and the account actions. Leaderboards live in the popover's Team
/// screen and the Teams window.
struct TeamsSettingsPane: View {
    @Environment(AppContainer.self) private var container
    private let density = DensitySetting.compact

    var body: some View {
        let teams = container.teams
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            if let message = teams.errorMessage {
                TeamsErrorBanner(message: message) { teams.dismissError() }
            }
            if teams.isSignedIn {
                TeamsInviteCard(teams: teams)
                TeamsAccountSection(teams: teams)
                TeamsListSection(teams: teams)
                if let teamID = teams.selectedTeamID, let summary = teams.teams.first(where: { $0.id == teamID }) {
                    TeamDetailSection(teams: teams, summary: summary)
                        .id(teamID)
                }
                TeamsAccountActionsSection(teams: teams)
            } else {
                TeamsSignedOutSection(teams: teams)
            }
        }
        .task { await teams.refresh() }
    }
}

struct TeamsErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.notice)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(10)
        .cardSurface()
    }
}

/// Sign in with Apple, styled like the app's other card buttons.
struct TeamsSignInButton: View {
    let teams: TeamsStore

    var body: some View {
        Button {
            Task { await teams.signIn() }
        } label: {
            Label("Sign In with Apple", systemImage: "applelogo")
                .frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .disabled(teams.isBusy)
    }
}

private struct TeamsSignedOutSection: View {
    let teams: TeamsStore

    var body: some View {
        SettingsSection("Teams") {
            SettingsCaption(
                "Create a team, invite friends with a link, and compare AI usage on a leaderboard. "
                    + "Members see each other's daily spend and tokens by provider and model. "
                    + "Credentials, logs, and project names never leave this Mac."
            )
            .padding(.top, 10)
            if teams.pendingInvite != nil {
                SettingsInlineNotice("Sign in to join the team you were invited to.")
            }
            TeamsSignInButton(teams: teams)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }
}

private struct TeamsInviteCard: View {
    let teams: TeamsStore

    var body: some View {
        if let invite = teams.pendingInvite {
            SettingsSection("Invitation") {
                if let preview = invite.preview {
                    if preview.alreadyMember {
                        SettingsRow("You're already in \(preview.team.name).") {
                            Button("OK") { teams.dismissPendingInvite() }
                        }
                    } else {
                        SettingsRow("Join \(preview.team.name)?") {
                            Text(preview.team.memberCount == 1 ? "1 member" : "\(preview.team.memberCount) members")
                                .foregroundStyle(.secondary)
                        }
                        SettingsCaption("Members of this team will see your daily AI spend and tokens.")
                        HStack {
                            Spacer()
                            Button("Not Now") { teams.dismissPendingInvite() }
                            Button("Join Team") { Task { await teams.acceptPendingInvite() } }
                                .keyboardShortcut(.defaultAction)
                                .disabled(teams.isBusy)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                } else {
                    SettingsRow("Loading invitation…") { ProgressView().controlSize(.small) }
                }
            }
        }
    }
}

private struct TeamsAccountSection: View {
    let teams: TeamsStore
    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        SettingsSection("Account") {
            HStack(spacing: 10) {
                Text(initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(teams.user?.displayName ?? "").fontWeight(.medium).lineLimit(1)
                    Text("Signed in with Apple").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Edit Name…") {
                    newName = teams.user?.displayName ?? ""
                    isRenaming = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            SettingsRow("This Mac") {
                Text(uploadStatus).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = teams.uploadError {
                SettingsInlineNotice(error)
            }
            Divider()
            SettingsRow("Show Rank in Menu Bar") {
                Toggle("", isOn: Binding(get: { teams.showRankInMenuBar }, set: { teams.showRankInMenuBar = $0 }))
                    .settingsSwitchStyle()
            }
            SettingsCaption("Your rank, your share of the team's spend, and your spend today in the selected team, next to your pinned metrics.")
        }
        .alert("Display Name", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != teams.user?.displayName else { return }
                Task { await teams.rename(to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown to your teammates on leaderboards.")
        }
    }

    private var initials: String {
        let words = (teams.user?.displayName ?? "?").split(separator: " ")
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var uploadStatus: String {
        if teams.teams.isEmpty { return "Not sharing (no teams yet)" }
        guard let lastUploadAt = teams.lastUploadAt else { return "Sharing usage" }
        return "Shared \(lastUploadAt.formatted(.relative(presentation: .named)))"
    }
}

private struct TeamsListSection: View {
    let teams: TeamsStore
    @State private var isCreating = false
    @State private var isJoining = false
    @State private var text = ""
    @State private var joinError: String?

    var body: some View {
        SettingsSection("Teams") {
            ForEach(Array(teams.teams.enumerated()), id: \.element.id) { index, team in
                if index > 0 { Divider() }
                teamRow(team)
            }
            if !teams.teams.isEmpty { Divider() }
            HStack {
                Button("New Team…") { text = ""; isCreating = true }
                Button("Join Team…") { text = ""; joinError = nil; isJoining = true }
                Spacer()
            }
            .disabled(teams.isBusy)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if let joinError {
                SettingsInlineNotice(joinError)
            }
        }
        .alert("New Team", isPresented: $isCreating) {
            TextField("Team name", text: $text)
            Button("Create") {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    if let team = await teams.createTeam(named: name) { teams.selectedTeamID = team.id }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be its owner and can invite people with a link.")
        }
        .alert("Join Team", isPresented: $isJoining) {
            TextField("Invite link", text: $text)
            Button("Join") {
                let link = text
                Task {
                    joinError = await teams.receiveInvite(link) ? nil : "That isn't a GodUsage invite link."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the invite link a team member shared with you.")
        }
    }

    private func teamRow(_ team: TeamSummary) -> some View {
        let isSelected = team.id == teams.selectedTeamID
        return Button {
            teams.selectedTeamID = team.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(team.name).lineLimit(1)
                if team.role == .owner {
                    Text("Owner")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                Text(team.memberCount == 1 ? "1 member" : "\(team.memberCount) members")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, DensitySetting.compact.controlRowPadding)
    }
}

private struct TeamsAccountActionsSection: View {
    let teams: TeamsStore
    @State private var confirmingDelete = false

    var body: some View {
        SettingsSection("Account Actions") {
            SettingsRow("Sign Out of Teams") {
                Button("Sign Out") { Task { await teams.signOut() } }
                    .disabled(teams.isBusy)
            }
            SettingsCaption("Removes this Mac's usage from your teams. Other Macs keep sharing until they sign out.")
            Divider()
            SettingsRow("Delete Account") {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(teams.isBusy)
            }
            SettingsCaption("Deletes your account, the usage every Mac shared, and the teams you own.")
        }
        .alert("Delete Teams Account?", isPresented: $confirmingDelete) {
            Button("Delete Account", role: .destructive) { Task { await teams.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your account, the usage every Mac shared, and the teams you own. It can't be undone.")
        }
    }
}
