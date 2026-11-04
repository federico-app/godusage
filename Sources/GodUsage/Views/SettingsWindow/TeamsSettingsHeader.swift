import SwiftUI

/// The pages of Settings → Teams: the selected team's members, which of this Mac's accounts count in
/// it, its plans (owners only), and the signed-in user's own account.
enum TeamsSettingsTab: String, CaseIterable, Identifiable {
    case members, accounts, plans, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .members: "Members"
        case .accounts: "Accounts"
        case .plans: "Plans"
        case .you: "You"
        }
    }

    /// The page Settings → Teams shows, kept across launches.
    static let storageKey = "godusage.settings.teamsTab"

    /// Opens Settings → Teams on `tab`.
    @MainActor
    static func open(_ tab: TeamsSettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
        SettingsWindowLink.open(pane: .teams)
    }

    /// The tabs a user sees: the team tabs only with a team selected, Plans only for its owners.
    static func available(for team: TeamSummary?) -> [TeamsSettingsTab] {
        guard let team else { return [.you] }
        return team.role == .owner ? allCases : [.members, .accounts, .you]
    }
}

/// The top of the signed-in Teams pane: which team the pane shows (its own pick, apart from the
/// popover's and the Teams window's), New Team and Join Team, and the page picker.
struct TeamsSettingsHeader: View {
    let teams: TeamsStore
    let teamID: String?
    let selectTeam: (String) -> Void
    @Binding var tab: TeamsSettingsTab
    @State private var isCreating = false
    @State private var isJoining = false
    @State private var text = ""
    @State private var joinError: String?

    private var selected: TeamSummary? { teams.teams.first { $0.id == teamID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if teams.teams.isEmpty {
                    Text("No teams yet. Create one and invite people with a link, or join one from an invite link.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Team", selection: Binding(
                        get: { teamID ?? "" },
                        set: { selectTeam($0) }
                    )) {
                        ForEach(teams.teams) { team in
                            Text(team.role == .owner ? "\(team.name) (Owner)" : team.name).tag(team.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if let selected {
                        Text(selected.memberCount == 1 ? "1 member" : "\(selected.memberCount) members")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("New Team…") { text = ""; isCreating = true }
                Button("Join Team…") { text = ""; joinError = nil; isJoining = true }
            }
            .disabled(teams.isBusy)
            if let joinError {
                Text(joinError).font(.caption).foregroundStyle(Theme.notice)
            }
            let tabs = TeamsSettingsTab.available(for: selected)
            if tabs.count > 1 {
                Picker("Page", selection: $tab) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onChange(of: TeamsSettingsTab.available(for: selected)) { _, tabs in
            if !tabs.contains(tab) { tab = tabs.first ?? .you }
        }
        .alert("New Team", isPresented: $isCreating) {
            TextField("Team name", text: $text)
            Button("Create") {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    if let team = await teams.createTeam(named: name) {
                        selectTeam(team.id)
                        tab = .members
                    }
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
}
