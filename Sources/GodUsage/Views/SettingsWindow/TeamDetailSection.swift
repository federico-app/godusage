import AppKit
import SwiftUI

/// The selected team in the Teams pane: its members, its invite and leaderboard links, and
/// leaving or deleting it. Owner-only controls appear only for owners. A team can have several
/// owners; the last one cannot leave.
struct TeamDetailSection: View {
    let teams: TeamsStore
    let summary: TeamSummary
    @State private var confirmation: Confirmation?
    @State private var copiedURL: URL?

    private enum Confirmation: Identifiable {
        case leave
        case delete
        case remove(TeamMember)
        case makeOwner(TeamMember)
        case newLink

        var id: String {
            switch self {
            case .leave: "leave"
            case .delete: "delete"
            case .remove(let member): "remove-\(member.id)"
            case .makeOwner(let member): "owner-\(member.id)"
            case .newLink: "new-link"
            }
        }
    }

    private var detail: TeamDetail? { teams.details[summary.id] }
    private var isOwner: Bool { summary.role == .owner }

    /// Owners can leave only while another owner stays to run the team.
    private func canLeave(_ detail: TeamDetail) -> Bool {
        !isOwner || detail.members.contains { $0.role == .owner && $0.id != teams.user?.id }
    }

    var body: some View {
        SettingsSection(summary.name) {
            if let detail {
                members(detail)
                Divider()
                links(detail)
                Divider()
                HStack {
                    Button("Open Leaderboards") { TeamsWindowLink.open() }
                    Spacer()
                    if canLeave(detail) {
                        Button("Leave Team…", role: .destructive) { confirmation = .leave }
                    }
                    if isOwner {
                        Button("Delete Team…", role: .destructive) { confirmation = .delete }
                    }
                }
                .disabled(teams.isBusy)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 12)
            }
        }
        .task { await teams.loadTeam(summary.id) }
        .alert(item: $confirmation) { alert(for: $0) }
    }

    @ViewBuilder
    private func members(_ detail: TeamDetail) -> some View {
        ForEach(detail.members) { member in
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(member.displayName).lineLimit(1)
                if member.id == teams.user?.id {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if member.role == .owner {
                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                }
                if isOwner, member.id != teams.user?.id {
                    Menu {
                        if member.role == .owner {
                            Button("Make Member") { Task { await teams.setRole(.member, of: member.id, in: summary.id) } }
                        } else {
                            Button("Make Owner…") { confirmation = .makeOwner(member) }
                        }
                        Button("Remove…", role: .destructive) { confirmation = .remove(member) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(teams.isBusy)
                    .accessibilityLabel("Manage \(member.displayName)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func links(_ detail: TeamDetail) -> some View {
        SettingsRow("Invite Link") {
            copyButton(detail.inviteURL)
            if isOwner {
                Button("New Link") { confirmation = .newLink }
            }
        }
        SettingsCaption("Anyone with the link can join and see the team's usage.")

        if let webBoardURL = detail.webBoardURL {
            SettingsRow("Web Leaderboard") {
                copyButton(webBoardURL)
                Button("Open") { NSWorkspace.shared.open(webBoardURL) }
            }
            SettingsCaption("Opens in a browser. Only members can see it, after signing in with Apple.")
        }

        if isOwner {
            SettingsRow("Public Leaderboard") {
                if let url = detail.publicBoardURL { copyButton(url) }
                Toggle("", isOn: Binding(
                    get: { detail.publicBoardURL != nil },
                    set: { shared in Task { await teams.setPublicBoard(detail.id, shared: shared) } }
                ))
                .settingsSwitchStyle()
                .disabled(teams.isBusy)
            }
            SettingsCaption("A read-only page anyone with its link can open, no sign-in needed.")
        }
    }

    private func copyButton(_ url: URL) -> some View {
        Button(copiedURL == url ? "Copied" : "Copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(url.absoluteString, forType: .string) else {
                AppLog.warn(.teams, "copying a team link to the clipboard failed")
                return
            }
            copiedURL = url
        }
    }

    private func alert(for confirmation: Confirmation) -> Alert {
        switch confirmation {
        case .leave:
            Alert(
                title: Text("Leave \(summary.name)?"),
                message: Text("You'll need a new invite link to join again."),
                primaryButton: .destructive(Text("Leave")) { Task { await teams.leaveTeam(summary.id) } },
                secondaryButton: .cancel()
            )
        case .delete:
            Alert(
                title: Text("Delete \(summary.name)?"),
                message: Text("The team and its leaderboard are deleted for everyone. Members keep their accounts."),
                primaryButton: .destructive(Text("Delete")) { Task { await teams.deleteTeam(summary.id) } },
                secondaryButton: .cancel()
            )
        case .remove(let member):
            Alert(
                title: Text("Remove \(member.displayName)?"),
                message: Text("They can rejoin only with the current invite link. Make a new link to keep them out."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await teams.removeMember(member.id, from: summary.id) }
                },
                secondaryButton: .cancel()
            )
        case .makeOwner(let member):
            Alert(
                title: Text("Make \(member.displayName) an Owner?"),
                message: Text("Owners can manage plans, links, and members, and delete the team."),
                primaryButton: .default(Text("Make Owner")) {
                    Task { await teams.setRole(.owner, of: member.id, in: summary.id) }
                },
                secondaryButton: .cancel()
            )
        case .newLink:
            Alert(
                title: Text("Make a New Invite Link?"),
                message: Text("The current link stops working. People who already joined stay in the team."),
                primaryButton: .default(Text("New Link")) { Task { await teams.rotateInvite(summary.id) } },
                secondaryButton: .cancel()
            )
        }
    }
}
