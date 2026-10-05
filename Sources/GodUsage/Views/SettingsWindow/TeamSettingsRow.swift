import AppKit
import SwiftUI

/// One team in the Teams pane: a summary row that expands into the invite link, the public board
/// (owner), members, and leave/delete.
struct TeamSettingsRow: View {
    let teams: TeamsStore
    let summary: TeamSummary
    @State private var expanded = false
    @State private var confirmation: Confirmation?
    @State private var copiedURL: URL?

    private enum Confirmation: Identifiable {
        case leave
        case delete
        case remove(TeamMember)
        case newLink

        var id: String {
            switch self {
            case .leave: "leave"
            case .delete: "delete"
            case .remove(let member): "remove-\(member.id)"
            case .newLink: "new-link"
            }
        }
    }

    private let density = DensitySetting.compact
    private var detail: TeamDetail? { teams.details[summary.id] }
    private var isOwner: Bool { summary.role == .owner }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Motion.spring) { expanded.toggle() }
                if expanded { Task { await teams.loadTeam(summary.id) } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary.name).lineLimit(1)
                    if isOwner {
                        Text("Owner")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(summary.memberCount == 1 ? "1 member" : "\(summary.memberCount) members")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)

            if expanded {
                if let detail {
                    expandedContent(detail)
                } else {
                    ProgressView().controlSize(.small).padding(.bottom, 10)
                }
            }
        }
        .alert(item: $confirmation) { confirmation in
            alert(for: confirmation)
        }
    }

    @ViewBuilder
    private func expandedContent(_ detail: TeamDetail) -> some View {
        SettingsRow("Invite Link") {
            copyButton(detail.inviteURL)
            if isOwner {
                Button("New Link") { confirmation = .newLink }
            }
        }
        SettingsCaption("Anyone with the link can join and see the team's usage.")

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
            SettingsCaption("A read-only web page anyone with its link can open, no sign-in needed.")
        }

        ForEach(detail.members) { member in
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(member.displayName).lineLimit(1)
                if member.id == teams.user?.id {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if member.role == .owner {
                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                } else if isOwner {
                    Button("Remove") { confirmation = .remove(member) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }

        HStack {
            Spacer()
            if isOwner {
                Button("Delete Team…", role: .destructive) { confirmation = .delete }
            } else {
                Button("Leave Team…", role: .destructive) { confirmation = .leave }
            }
        }
        .disabled(teams.isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
