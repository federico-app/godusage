import SwiftUI

/// "N accounts" next to a plan in This Week's Limit. A click lists each account of the open week: who
/// reads it, how much of its week it used, and when it resets. Plain text from servers before the list.
/// Owners can hide an account from the plan (a member's own login beside the shared one) and show it
/// again; a hidden account stays out of the plan's quota figures, its usage still counts.
struct TeamPlanAccountsButton: View {
    let teamID: String
    let plan: TeamPlanReport
    let budget: TeamPlanBudget

    @State private var showsAccounts = false

    /// More than one account, or one left beside accounts an owner hid (so they can be shown again).
    static func isShown(budget: TeamPlanBudget, plan: TeamPlanReport) -> Bool {
        budget.accounts > 1 || !(plan.hiddenAccounts ?? []).isEmpty
    }

    var body: some View {
        let hidden = plan.hiddenAccounts?.count ?? 0
        let label = Text(Self.label(accounts: budget.accounts, hidden: hidden))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        if let accounts = budget.perAccount, !accounts.isEmpty {
            Button { showsAccounts.toggle() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Show the \(budget.accounts) accounts")
                .popover(isPresented: $showsAccounts, arrowEdge: .bottom) {
                    TeamPlanAccountsList(teamID: teamID, plan: plan, accounts: accounts)
                }
        } else {
            label.fixedSize()
        }
    }

    /// "2 accounts", "1 account · 1 hidden".
    static func label(accounts: Int, hidden: Int) -> String {
        let count = accounts == 1 ? "1 account" : "\(accounts) accounts"
        return hidden == 0 ? count : "\(count) · \(hidden) hidden"
    }
}

private struct TeamPlanAccountsList: View {
    @Environment(AppContainer.self) private var container
    let teamID: String
    let plan: TeamPlanReport
    let accounts: [TeamPlanBudget.AccountWeek]

    @State private var busy: String?
    @State private var failed = false

    private var store: TeamPlansStore { container.teamPlans }
    private var canEdit: Bool { store.report(teamID: teamID)?.canEdit ?? false }
    private var hiddenKeys: [String] { plan.hiddenAccounts ?? [] }
    private var hiddenWeeks: [TeamPlanBudget.AccountWeek] { plan.hiddenPerAccount ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts This Week").font(.caption.weight(.semibold))
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                // The last account left can't be hidden: the plan would have no week.
                row(account, action: canEdit && accounts.count > 1 ? ("Hide", true) : nil)
                if index == 0, accounts.count > 1 {
                    Text("Resets first, so it sets the week.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if canEdit, !hiddenKeys.isEmpty {
                Divider()
                Text("Hidden From This Plan").font(.caption.weight(.semibold))
                ForEach(Array(hiddenWeeks.enumerated()), id: \.offset) { _, account in
                    row(account, action: ("Show", false))
                }
                let withoutWeek = hiddenKeys.filter { key in !hiddenWeeks.contains { $0.account == key } }
                if !withoutWeek.isEmpty {
                    HStack(spacing: 8) {
                        Text(withoutWeek.count == 1 ? "1 more with no open week" : "\(withoutWeek.count) more with no open week")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Show All") { show(withoutWeek) }
                            .controlSize(.small)
                            .disabled(busy != nil)
                    }
                }
                Text("Hidden accounts stay out of this plan's quota figures. Their usage still counts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if canEdit, accounts.count > 1 {
                Text("Hide an account that isn't this plan's, like someone's own login.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if failed {
                Text(store.errorMessage ?? "Couldn't change the plan's accounts. Try again.").font(.caption2).foregroundStyle(Theme.notice)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ account: TeamPlanBudget.AccountWeek, action: (title: String, hidden: Bool)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TeamPlanAccountsButton.readBy(account.people)).font(.caption.weight(.semibold))
                Text(TeamPlanAccountsButton.usage(account)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if account.perDevice {
                    Text("Named per Mac: may be the same login as another account")
                        .font(.caption2)
                        .foregroundStyle(Theme.notice)
                }
            }
            Spacer(minLength: 8)
            if let action, let key = account.account {
                if busy == key {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action.title) { set([key], hidden: action.hidden) }
                        .controlSize(.small)
                        .disabled(busy != nil)
                }
            }
        }
    }

    private func show(_ keys: [String]) { set(keys, hidden: false) }

    private func set(_ keys: [String], hidden: Bool) {
        busy = keys.first
        failed = false
        Task {
            for key in keys {
                let saved = await store.setAccountHidden(teamID: teamID, planID: plan.id, account: key, hidden: hidden)
                if !saved {
                    failed = true
                    break
                }
            }
            busy = nil
        }
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
