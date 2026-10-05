import SwiftUI

/// The Settings window's Teams pane: the Sign in with Apple account, invites, and team management.
/// Leaderboards live in the Teams window (`TeamsWindowLink`).
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
                TeamsCreateJoinSection(teams: teams)
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
                        SettingsCaption("You're already in \(preview.team.name).")
                            .padding(.top, 10)
                        SettingsCardButton("OK") { teams.dismissPendingInvite() }
                    } else {
                        SettingsRow("Join \(preview.team.name)?") {
                            Text(preview.team.memberCount == 1 ? "1 member" : "\(preview.team.memberCount) members")
                                .foregroundStyle(.secondary)
                        }
                        SettingsCaption("Members of this team will see your daily AI spend and tokens.")
                        HStack {
                            Button("Not Now") { teams.dismissPendingInvite() }
                            Spacer()
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
    @State private var name = ""
    @State private var confirmingDelete = false

    var body: some View {
        SettingsSection("Account") {
            SettingsRow("Display Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(trimmedName.isEmpty || trimmedName == teams.user?.displayName || teams.isBusy)
            }
            SettingsCaption("Shown to your teammates on leaderboards.")
            Divider()
            SettingsRow("This Mac") {
                Text(uploadStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let error = teams.uploadError {
                SettingsInlineNotice(error)
            }
            Divider()
            HStack {
                Button("Sign Out") { Task { await teams.signOut() } }
                Spacer()
                Button("Delete Account…", role: .destructive) { confirmingDelete = true }
            }
            .disabled(teams.isBusy)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            SettingsCaption("Signing out removes this Mac's usage from your teams. Other Macs keep sharing until they sign out.")
        }
        .onAppear { name = teams.user?.displayName ?? "" }
        .onChange(of: teams.user?.displayName) { name = teams.user?.displayName ?? "" }
        .alert("Delete Teams Account?", isPresented: $confirmingDelete) {
            Button("Delete Account", role: .destructive) { Task { await teams.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your account, the usage every Mac shared, and the teams you own. It can't be undone.")
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmedName.isEmpty, trimmedName != teams.user?.displayName else { return }
        Task { await teams.rename(to: trimmedName) }
    }

    private var uploadStatus: String {
        if teams.teams.isEmpty { return "Not sharing (no teams yet)" }
        guard let lastUploadAt = teams.lastUploadAt else { return "Sharing usage" }
        return "Shared \(lastUploadAt.formatted(.relative(presentation: .named)))"
    }
}

private struct TeamsListSection: View {
    let teams: TeamsStore

    var body: some View {
        if !teams.teams.isEmpty {
            SettingsSection("Your Teams") {
                ForEach(Array(teams.teams.enumerated()), id: \.element.id) { index, team in
                    if index > 0 { Divider() }
                    TeamSettingsRow(teams: teams, summary: team)
                }
                Divider()
                SettingsCardButton("Open Leaderboards") { TeamsWindowLink.open() }
            }
        }
    }
}

private struct TeamsCreateJoinSection: View {
    let teams: TeamsStore
    @State private var newTeamName = ""
    @State private var inviteText = ""
    @State private var inviteError: String?

    var body: some View {
        SettingsSection("Add a Team") {
            SettingsRow("New Team") {
                TextField("Name", text: $newTeamName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(create)
                Button("Create", action: create)
                    .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty || teams.isBusy)
            }
            Divider()
            SettingsRow("Invite Link") {
                TextField("Paste link", text: $inviteText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(join)
                Button("Join", action: join)
                    .disabled(inviteText.trimmingCharacters(in: .whitespaces).isEmpty || teams.isBusy)
            }
            if let inviteError {
                SettingsInlineNotice(inviteError)
            }
        }
    }

    private func create() {
        let name = newTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            if await teams.createTeam(named: name) != nil { newTeamName = "" }
        }
    }

    private func join() {
        Task {
            if await teams.receiveInvite(inviteText) {
                inviteText = ""
                inviteError = nil
            } else {
                inviteError = "That isn't a GodUsage invite link."
            }
        }
    }
}
