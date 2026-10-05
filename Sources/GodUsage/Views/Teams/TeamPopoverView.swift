import SwiftUI

/// The popover's Team screen: the selected team's ranking at a glance, with each member's split by
/// provider. Click a member for their providers and top models. The Teams window (top bar button)
/// has the full charts.
struct TeamPopoverView: View {
    @Environment(AppContainer.self) private var container
    let heightCoordinator: PanelHeightCoordinator
    let horizontalPadding: CGFloat

    @AppStorage("godusage.teams.popover.range") private var range: StatsRange = .today
    @AppStorage("godusage.teams.popover.sort") private var sort: StatsSort = .cost
    @State private var expandedMemberID: String?
    @State private var isLoading = false

    private let density = DensitySetting.compact

    var body: some View {
        PopoverScrollView(heightCoordinator: heightCoordinator, screen: .team) {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .task(id: loadKey) { await load() }
    }

    private struct LoadKey: Hashable {
        var teamID: String?
        var range: StatsRange
        var sort: StatsSort
    }

    private var loadKey: LoadKey {
        LoadKey(teamID: container.teams.selectedTeamID, range: range, sort: sort)
    }

    private var stats: TeamStats? {
        guard let teamID = container.teams.selectedTeamID else { return nil }
        return container.teams.cachedStats[TeamsStore.StatsKey(teamID: teamID, range: range, sort: sort)]
    }

    private func load() async {
        let teams = container.teams
        if teams.teams.isEmpty, teams.isSignedIn { await teams.refresh() }
        guard let teamID = teams.selectedTeamID else { return }
        isLoading = true
        await teams.loadStats(teamID: teamID, range: range, sort: sort)
        isLoading = false
    }

    @ViewBuilder
    private var content: some View {
        let teams = container.teams
        if !teams.isSignedIn {
            emptyCard(
                title: "Compare Usage With Friends",
                message: "Sign in with Apple in Teams settings, then create a team or open an invite link.",
                button: "Open Teams Settings"
            )
        } else if teams.teams.isEmpty {
            emptyCard(
                title: "No Teams Yet",
                message: "Create a team or join one with an invite link in Teams settings.",
                button: "Open Teams Settings"
            )
        } else {
            controls
            if let stats {
                summary(stats)
                ranking(stats)
            } else if let error = teams.statsError {
                errorCard(error)
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 24)
            }
            if stats != nil, let error = teams.statsError {
                Text(error).font(.caption).foregroundStyle(Theme.notice)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                teamPicker
                Spacer(minLength: 4)
                if isLoading { ProgressView().controlSize(.mini) }
                Picker("Metric", selection: $sort) {
                    ForEach(StatsSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Picker("Range", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var teamPicker: some View {
        let teams = container.teams
        if teams.teams.count > 1 {
            Menu {
                ForEach(teams.teams) { team in
                    Button(team.name) { teams.selectedTeamID = team.id }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currentTeamName).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(currentTeamName).font(.headline).lineLimit(1)
        }
    }

    private var currentTeamName: String {
        let teams = container.teams
        return teams.teams.first { $0.id == teams.selectedTeamID }?.name ?? "Team"
    }

    // MARK: - Board

    private func summary(_ stats: TeamStats) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(TeamsFormat.value(stats.totals, sort: sort))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(sort == .cost ? "team spend" : "team tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func ranking(_ stats: TeamStats) -> some View {
        let top = stats.members.map { $0.totals.value(for: sort) }.max() ?? 0
        return VStack(spacing: 0) {
            ForEach(Array(stats.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 12) }
                memberRow(member, top: top, stats: stats)
            }
        }
        .cardSurface()
    }

    private func memberRow(_ member: TeamStats.Member, top: Double, stats: TeamStats) -> some View {
        let isExpanded = expandedMemberID == member.userID
        let isMe = member.userID == container.teams.user?.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spring) { expandedMemberID = isExpanded ? nil : member.userID }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(member.rank)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(member.rank == 1 ? .primary : .secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(member.displayName)
                            .fontWeight(isMe ? .semibold : .regular)
                            .lineLimit(1)
                        if isMe {
                            Text("You")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 6)
                        Text(TeamsFormat.value(member.totals, sort: sort))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    providerBar(member, top: top)
                        .padding(.leading, 26)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                memberDetail(member, stats: stats)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func providerBar(_ member: TeamStats.Member, top: Double) -> some View {
        ProviderSplitBar(providers: member.providers, top: top, sort: sort)
    }

    @ViewBuilder
    private func memberDetail(_ member: TeamStats.Member, stats: TeamStats) -> some View {
        let providers = member.providers.filter { $0.totals.value(for: sort) > 0 }
        let models = stats.models
            .compactMap { model -> (TeamStats.Model, UsageTotals)? in
                guard let mine = model.members.first(where: { $0.userID == member.userID }) else { return nil }
                return (model, mine.totals)
            }
            .filter { $0.1.value(for: sort) > 0 }
            .sorted { $0.1.value(for: sort) > $1.1.value(for: sort) }
            .prefix(3)
        VStack(alignment: .leading, spacing: 4) {
            if providers.isEmpty {
                Text("No usage in this period.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                detailRow(color: TotalSpendPalette.color(for: provider.provider), title: providerName(provider.provider), totals: provider.totals)
            }
            if !models.isEmpty {
                Text("Top Models")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(Array(models), id: \.0.id) { model, totals in
                    detailRow(color: TotalSpendPalette.color(for: model.provider), title: model.model, totals: totals)
                }
            }
        }
    }

    private func detailRow(color: Color, title: String, totals: UsageTotals) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(TeamsFormat.value(totals, sort: sort))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func providerName(_ id: String) -> String {
        container.registry.providers.first { $0.id == id }?.displayName ?? id.capitalized
    }

    // MARK: - Empty and error states

    private func emptyCard(title: String, message: String, button: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "person.3").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(button) { SettingsWindowLink.open(pane: .teams) }
                .glassButtonStyle()
                .controlSize(.regular)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .cardSurface()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(Theme.notice).multilineTextAlignment(.center)
            Button("Try Again") { Task { await load() } }.controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .cardSurface()
    }
}
