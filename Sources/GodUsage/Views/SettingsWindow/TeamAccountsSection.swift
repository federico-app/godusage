import SwiftUI

/// Which of this Mac's accounts count in the selected team. Turning one off leaves its usage, quota,
/// and ⚡ out of this team only; teammates don't see it. The choice is kept per Mac.
struct TeamAccountsSection: View {
    @Environment(AppContainer.self) private var container
    let teams: TeamsStore
    let summary: TeamSummary

    var body: some View {
        let cardIDs = teams.shareableCardIDs()
        if isViewer {
            SettingsSection("Accounts Counted in \(summary.name)") {
                SettingsCaption("An owner made you a viewer, so none of your accounts count in this team.")
            }
        } else if !cardIDs.isEmpty {
            SettingsSection("Accounts Counted in \(summary.name)") {
                ForEach(cardIDs, id: \.self) { cardID in
                    SettingsRow(name(of: cardID)) {
                        Toggle("", isOn: Binding(
                            get: { teams.isCardCounted(cardID, in: summary.id) },
                            set: { teams.setCardCounted($0, cardID: cardID, in: summary.id) }
                        ))
                        .settingsSwitchStyle()
                    }
                }
                SettingsCaption("Turn off an account, like a personal plan, to leave its usage out of this team. Teammates don't see it. Applies to this Mac.")
            }
        }
    }

    /// An owner left this user's usage out of the team.
    private var isViewer: Bool {
        teams.details[summary.id]?.members.first { $0.id == teams.user?.id }.map { !$0.counts && $0.role == .member } ?? false
    }

    private func name(of cardID: String) -> String {
        container.layout.provider(id: cardID).map { container.displayName(for: $0) } ?? cardID
    }
}
