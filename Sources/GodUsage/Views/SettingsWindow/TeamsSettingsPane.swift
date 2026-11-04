import AppKit
import SwiftUI

/// The Settings window's Teams pane: a pending invitation, the team picker, and one page at a time
/// (see `TeamsSettingsTab`): the selected team's members and links, which accounts count in it, its
/// plans, and the user's own account. Leaderboards live in the popover's Team screen and the Teams
/// window.
struct TeamsSettingsPane: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(TeamsSettingsTab.storageKey) private var tab: TeamsSettingsTab = .members
    private let density = DensitySetting.compact

    var body: some View {
        let teams = container.teams
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            if let message = teams.errorMessage {
                TeamsErrorBanner(message: message) { teams.dismissError() }
            }
            if teams.isSignedIn {
                TeamsInviteCard(teams: teams)
                TeamsSettingsHeader(teams: teams, tab: $tab)
                let summary = teams.teams.first { $0.id == teams.selectedTeamID }
                switch TeamsSettingsTab.available(for: summary).contains(tab) ? tab : .you {
                case .members:
                    if let summary { TeamDetailSection(teams: teams, summary: summary).id(summary.id) }
                case .accounts:
                    if let summary { TeamAccountsSection(teams: teams, summary: summary) }
                case .plans:
                    if let summary { TeamPlansSection(teamID: summary.id).id(summary.id) }
                case .you:
                    TeamsAccountSection(teams: teams)
                    TeamsLinkedDevicesSection()
                    TeamsAccountActionsSection(teams: teams)
                }
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
            TeamsLegalLinks(prefix: "By signing in you agree to the")
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// "… the Terms and the Privacy Policy" of the Teams service (served by the backend).
struct TeamsLegalLinks: View {
    var prefix: String? = nil

    var body: some View {
        let client = TeamsAPIClient()
        HStack(spacing: 4) {
            if let prefix { Text(prefix) }
            Link("Terms", destination: client.termsURL)
            Text("and the")
            Link("Privacy Policy", destination: client.privacyURL)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
    @Environment(AppContainer.self) private var container
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
            DeviceIdentityNotice(identity: container.deviceIdentity) {
                teams.scheduleUpload(force: true)
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

/// Shown while this Mac's device id is unresolved or not durable. Recover Identity reads a legacy
/// Keychain item with the user present, then uploads under the recovered id.
private struct DeviceIdentityNotice: View {
    let identity: DeviceIdentityStore
    let onRecovered: () -> Void

    var body: some View {
        if let error = identity.identityError {
            SettingsInlineNotice(error)
            if identity.canRecoverIdentity {
                Button("Recover Identity") {
                    Task {
                        await identity.recoverIdentity()
                        if !identity.isProvisional { onRecovered() }
                    }
                }
                .controlSize(.small)
                .disabled(identity.isRecovering)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TeamsAccountActionsSection: View {
    let teams: TeamsStore
    @State private var confirmingDelete = false
    @State private var exportMessage: String?

    private func export() {
        Task {
            guard let data = await teams.exportData() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "godusage-export.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                exportMessage = "Saved \(url.lastPathComponent)."
            } catch {
                AppLog.error(.teams, "export save failed: \(error.localizedDescription)")
                exportMessage = "Couldn't save the file: \(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        SettingsSection("Account Actions") {
            SettingsRow("Sign Out of Teams") {
                Button("Sign Out") { Task { await teams.signOut() } }
                    .disabled(teams.isBusy)
            }
            SettingsCaption("Removes this Mac's usage from your teams. Other Macs keep sharing until they sign out.")
            Divider()
            SettingsRow("Your Data") {
                Button("Export My Data…") { export() }
                    .disabled(teams.isBusy)
            }
            SettingsCaption("Saves everything the Teams service keeps about you as a JSON file.")
            if let exportMessage {
                SettingsCaption(exportMessage)
            }
            Divider()
            SettingsRow("Delete Account") {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(teams.isBusy)
            }
            SettingsCaption("Deletes your account, the usage every Mac shared, and the teams you own.")
            TeamsLegalLinks(prefix: "See the")
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .alert("Delete Teams Account?", isPresented: $confirmingDelete) {
            Button("Delete Account", role: .destructive) { Task { await teams.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your account, the usage every Mac shared, and the teams you own. It can't be undone.")
        }
    }
}
