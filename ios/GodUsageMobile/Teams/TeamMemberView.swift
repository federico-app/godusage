import SwiftUI

/// One member of a team's leaderboard: their rank and movement, total, and spend and tokens per
/// provider for the range the board shows.
struct TeamMemberView: View {
    let member: TeamBoard.Member
    let range: BoardRange
    let isMe: Bool

    var body: some View {
        List {
            Section {
                LabeledContent("Rank") {
                    Text(verbatim: "\(member.rank)").monospacedDigit()
                }
                if let change = member.rankChange {
                    Text(range.movement(change))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Spend") {
                    Text(TeamsFormat.cost(member.costUSD)).monospacedDigit()
                }
                LabeledContent("Tokens") {
                    Text(TeamsFormat.tokens(member.tokens)).monospacedDigit()
                }
            } header: {
                Text(range.title)
            } footer: {
                if let age = TeamsFormat.syncAge(member.lastSyncAt) {
                    Text(age)
                }
            }
            Section("Providers") {
                if member.providers.isEmpty {
                    Text("No usage in this period.")
                        .foregroundStyle(.secondary)
                }
                ForEach(member.providers) { provider in
                    LabeledContent(TeamsFormat.providerName(provider.provider)) {
                        Text(verbatim: "\(TeamsFormat.cost(provider.costUSD)) · \(TeamsFormat.tokens(provider.tokens))")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        isMe ? String(localized: "\(member.displayName) (You)", comment: "The signed-in user's own row in the leaderboard") : member.displayName
    }
}
