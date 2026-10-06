import SwiftUI

/// Settings → Teams: the subscriptions the selected team pays for. Only the owner edits them; the
/// Plans tab of the Teams window compares each one with the team's usage at API prices.
struct TeamPlansSection: View {
    @Environment(AppContainer.self) private var container
    let teamID: String

    @State private var drafts: [TeamPlan] = []
    @State private var loaded = false

    private var store: TeamPlansStore { container.teamPlans }
    private var saved: [TeamPlan] { store.report(teamID: teamID)?.plans.map(\.plan) ?? [] }

    var body: some View {
        SettingsSection("Plans") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The subscriptions this team pays for. The Plans tab in the Teams window compares each with the team's usage at API prices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if drafts.isEmpty, loaded {
                    Text("No plans yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach($drafts) { $plan in
                    Divider()
                    planRow($plan)
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Theme.notice)
                }
                HStack {
                    Button("Add Plan") { drafts.append(newPlan()) }
                        .disabled(drafts.count >= 30)
                    Spacer()
                    if store.isSaving { ProgressView().controlSize(.small) }
                    Button("Revert") { drafts = saved }
                        .disabled(!hasChanges || store.isSaving)
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges || !isValid || store.isSaving)
                }
            }
            .padding(12)
        }
        .task(id: teamID) {
            await store.load(teamID: teamID)
            drafts = saved
            loaded = true
        }
    }

    private var hasChanges: Bool { drafts != saved }

    private var isValid: Bool {
        drafts.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.monthlyCostUSD > 0 }
    }

    private func save() async {
        let trimmed = drafts.map { plan in
            var copy = plan
            copy.name = plan.name.trimmingCharacters(in: .whitespaces)
            return copy
        }
        if await store.save(teamID: teamID, plans: trimmed) { drafts = saved }
    }

    private func newPlan() -> TeamPlan {
        let provider = container.registry.providers.first?.id ?? "claude"
        return TeamPlan(
            provider: provider,
            name: providerName(provider),
            monthlyCostUSD: 20,
            renewalDay: Calendar.current.component(.day, from: Date())
        )
    }

    /// Two lines so a plan fits the Settings width: provider and name, then cost and renewal day.
    private func planRow(_ plan: Binding<TeamPlan>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Provider", selection: plan.provider) {
                    ForEach(container.registry.providers, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Name", text: plan.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Button {
                    drafts.removeAll { $0.id == plan.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(plan.wrappedValue.name)")
            }
            HStack(spacing: 8) {
                TextField("Monthly Cost", value: plan.monthlyCostUSD, format: .currency(code: "USD"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("/ mo").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Renews", selection: plan.renewalDay) {
                    ForEach(1...31, id: \.self) { day in Text("Renews on day \(day)").tag(day) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }

    private func providerName(_ id: String) -> String {
        container.registry.providers.first { $0.id == id }?.displayName ?? id.capitalized
    }
}
