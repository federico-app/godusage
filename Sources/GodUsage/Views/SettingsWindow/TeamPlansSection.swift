import SwiftUI

/// Settings → Teams: the subscriptions the selected team pays for and who each covers. Only the
/// owner edits them; the Plans tab of the Teams window compares each one with the covered members'
/// usage at API prices.
struct TeamPlansSection: View {
    @Environment(AppContainer.self) private var container
    let teamID: String

    @State private var drafts: [TeamPlan] = []
    @State private var loaded = false
    @State private var editing: TeamPlanChangeEditor.Draft?

    private var store: TeamPlansStore { container.teamPlans }
    private var saved: [TeamPlan] { store.report(teamID: teamID)?.plans.map(\.plan) ?? [] }
    /// Who a plan can cover: owners who don't count toward the team are left out.
    private var members: [TeamMember] { container.teams.details[teamID]?.members.filter(\.counts) ?? [] }
    private var today: String { container.teams.localToday() }

    var body: some View {
        SettingsSection("Plans") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The subscriptions this team pays for and who each one covers. The Plans tab in the Teams window compares each with its members' usage at API prices.")
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
            if container.teams.details[teamID] == nil { await container.teams.loadTeam(teamID) }
            await store.load(teamID: teamID)
            drafts = saved.map(prefillingLink)
            loaded = true
        }
        .sheet(item: $editing) { draft in
            TeamPlanChangeEditor(draft: draft) { result in applyChange(result) }
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

    /// Plan changes, ignores, and links made from a plan's notes save at once, with any other edits.
    /// While another edit is invalid they wait for Save like the rest.
    private func update(_ planID: String, _ change: (inout TeamPlan) -> Void) {
        guard let index = drafts.firstIndex(where: { $0.id == planID }) else { return }
        change(&drafts[index])
        if isValid { Task { await save() } }
    }

    private func newPlan() -> TeamPlan {
        let provider = container.registry.teamProviders.first?.id ?? "claude"
        return TeamPlan(
            provider: provider,
            name: providerName(provider),
            monthlyCostUSD: 20,
            renewalDay: Calendar.current.component(.day, from: Date())
        )
    }

    // MARK: - Detected plans

    private func detectedLabels(for plan: TeamPlan) -> [String] {
        TeamPlanChanges.detectedLabels(store.report(teamID: teamID)?.detectedPlans ?? [], provider: plan.provider, memberIDs: plan.memberIDs)
    }

    /// A plan with no linked detected plan links to the only one its members' Macs detect.
    private func prefillingLink(_ plan: TeamPlan) -> TeamPlan {
        var copy = plan
        copy.detectedPlan = TeamPlanChanges.prefilledLink(plan, labels: detectedLabels(for: plan)) ?? plan.detectedPlan
        return copy
    }

    private func mismatches(of plan: TeamPlan) -> [TeamPlanMismatch] {
        store.report(teamID: teamID)?.plans.first { $0.id == plan.id }?.mismatches ?? []
    }

    // MARK: - Rows

    /// Two lines so a plan fits the Settings width: provider and name, then cost and renewal day;
    /// then coverage and the detected plan, the plan's changes, and any detected mismatch.
    private func planRow(_ plan: Binding<TeamPlan>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Provider", selection: plan.provider) {
                    ForEach(container.registry.teamProviders, id: \.id) { provider in
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
            HStack(spacing: 8) {
                Text("Covers").font(.caption).foregroundStyle(.secondary)
                coverageMenu(plan.memberIDs)
                detectedPlanMenu(plan)
                Spacer()
                Button("Change Plan…") { editing = changeDraft(for: plan.wrappedValue) }
                    .controlSize(.small)
            }
            changeLines(plan.wrappedValue)
            ForEach(mismatches(of: plan.wrappedValue), id: \.self) { mismatch in
                mismatchNote(mismatch, plan: plan.wrappedValue)
            }
        }
        .padding(.vertical, 4)
    }

    /// The plan's changes in this cycle or later: "↓ Downgrade to … from Nov 30 (next renewal)".
    @ViewBuilder
    private func changeLines(_ plan: TeamPlan) -> some View {
        ForEach(plan.visibleChanges(today: today), id: \.effectiveFrom) { change in
            HStack(spacing: 8) {
                Text(TeamPlanChanges.describe(change, renewalDay: plan.renewalDay, today: today))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Change") {
                    update(plan.id) { $0.cancelChange(effectiveFrom: change.effectiveFrom, today: today) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// "⚠ Detected Max 5x on Bea's Mac. This plan says Max 20x ($200/mo)."
    private func mismatchNote(_ mismatch: TeamPlanMismatch, plan: TeamPlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.notice).font(.caption)
            Text("Detected \(mismatch.detectedPlan) on \(mismatch.displayName)’s Mac. This plan says \(plan.detectedPlan ?? plan.name) (\(TeamPlanChanges.monthly(plan.monthlyCostUSD))/mo).")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Update Payment…") { editing = changeDraft(for: plan, from: mismatch) }
                .controlSize(.small)
            Button("Ignore") {
                update(plan.id) { $0.ignoredPlans.append(mismatch.detectedPlan) }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Changes

    /// A hand-marked change starts at the next renewal; one from a mismatch on the day the member's
    /// Mac first detected the new plan, named after it.
    private func changeDraft(for plan: TeamPlan, from mismatch: TeamPlanMismatch? = nil) -> TeamPlanChangeEditor.Draft {
        let earliest = plan.earliestChangeDay(today: today)
        var day = mismatch?.detectedOn ?? TeamPlanChanges.nextRenewal(renewalDay: plan.renewalDay, today: today)
        if let earliest, day < earliest { day = earliest }
        return TeamPlanChangeEditor.Draft(
            planID: plan.id,
            planName: plan.name,
            name: mismatch?.detectedPlan ?? plan.name,
            monthlyCostUSD: mismatch == nil ? plan.monthlyCostUSD : nil,
            effective: TeamsFormat.date(day) ?? Date(),
            earliest: earliest.flatMap(TeamsFormat.date),
            linkDetectedPlan: mismatch?.detectedPlan
        )
    }

    private func applyChange(_ draft: TeamPlanChangeEditor.Draft) {
        guard let cost = draft.monthlyCostUSD else { return }
        let day = DailyUsageAccumulator.dayKey(from: draft.effective, calendar: .current)
        let terms = TeamPlanTerms(name: draft.name.trimmingCharacters(in: .whitespaces), monthlyCostUSD: cost)
        update(draft.planID) { plan in
            plan.addChange(effectiveFrom: day, to: terms, today: today)
            if let label = draft.linkDetectedPlan { plan.detectedPlan = label }
        }
    }

    // MARK: - Menus

    /// Which detected plan this plan stands for, from those detected on its members' Macs.
    @ViewBuilder
    private func detectedPlanMenu(_ plan: Binding<TeamPlan>) -> some View {
        let labels = detectedLabels(for: plan.wrappedValue)
        let linked = plan.wrappedValue.detectedPlan
        if !labels.isEmpty || linked != nil {
            Text("Detected As").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("None") { plan.wrappedValue.detectedPlan = nil }
                Divider()
                ForEach(labels + (linked.map { link in labels.contains { TeamPlanChanges.sameLabel($0, link) } ? [] : [link] } ?? []), id: \.self) { label in
                    Button(label) { plan.wrappedValue.detectedPlan = label }
                }
            } label: {
                Text(linked ?? "None")
            }
            .fixedSize()
        }
    }

    /// Everyone (members who join later too), or the members picked here. At least one stays picked.
    private func coverageMenu(_ memberIDs: Binding<[String]?>) -> some View {
        Menu {
            Toggle("Everyone", isOn: Binding(
                get: { memberIDs.wrappedValue == nil },
                set: { if $0 { memberIDs.wrappedValue = nil } }
            ))
            Divider()
            ForEach(members) { member in
                let picked = memberIDs.wrappedValue?.contains(member.id) ?? true
                Toggle(member.displayName, isOn: Binding(
                    get: { memberIDs.wrappedValue?.contains(member.id) ?? false },
                    set: { on in
                        var ids = memberIDs.wrappedValue ?? []
                        if on { ids.append(member.id) } else { ids.removeAll { $0 == member.id } }
                        memberIDs.wrappedValue = ids
                    }
                ))
                .disabled(picked && memberIDs.wrappedValue?.count == 1)
            }
        } label: {
            Text(coverageLabel(memberIDs.wrappedValue))
        }
        .fixedSize()
    }

    private func coverageLabel(_ memberIDs: [String]?) -> String {
        guard let memberIDs else { return "Everyone" }
        let names = members.filter { memberIDs.contains($0.id) }.map(\.displayName)
        return names.count == 1 ? names[0] : "\(names.count) Members"
    }

    private func providerName(_ id: String) -> String {
        container.registry.teamProviderName(id)
    }
}
