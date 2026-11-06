import SwiftUI

/// "N accounts" next to a plan in This Week's Limit. A click lists each account of the open week: who
/// reads it, how much of its week it used, and when it resets. Plain text from servers before the list.
struct TeamPlanAccountsButton: View {
    let budget: TeamPlanBudget

    @State private var showsAccounts = false

    var body: some View {
        let label = Text("\(budget.accounts) accounts").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
        if let accounts = budget.perAccount, !accounts.isEmpty {
            Button { showsAccounts.toggle() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Show the \(budget.accounts) accounts")
                .popover(isPresented: $showsAccounts, arrowEdge: .bottom) {
                    TeamPlanAccountsList(accounts: accounts)
                }
        } else {
            label.fixedSize()
        }
    }
}

private struct TeamPlanAccountsList: View {
    let accounts: [TeamPlanBudget.AccountWeek]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts This Week").font(.caption.weight(.semibold))
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(TeamPlanAccountsButton.readBy(account.people)).font(.caption.weight(.semibold))
                    Text(TeamPlanAccountsButton.usage(account)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if account.perDevice {
                        Text("Named per Mac: may be the same login as another account")
                            .font(.caption2)
                            .foregroundStyle(Theme.notice)
                    }
                }
                if index == 0, accounts.count > 1 {
                    Text("Resets first, so it sets the week.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension TeamPlanAccountsButton {
    /// "You and Matteo Scoccia", or "Matteo Scoccia, Anna and Luca".
    static func readBy(_ people: [String]) -> String {
        guard let last = people.last else { return "Nobody" }
        let rest = people.dropLast()
        return rest.isEmpty ? last : "\(rest.joined(separator: ", ")) and \(last)"
    }

    /// "42.0% of the week · 6.0% today · resets Thu 09:00".
    static func usage(_ account: TeamPlanBudget.AccountWeek) -> String {
        let reset = GodUsageISO8601.date(from: account.resetsAt).map(LivePaceFormat.weekdayTime) ?? account.resetsAt
        return "\(TeamWeekStrip.percent(account.percent)) of the week · \(TeamWeekStrip.percent(account.todayPercent)) today · resets \(reset)"
    }
}
