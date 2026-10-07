import SwiftUI

/// How the dashboard's Team section looks, set from the Team card in Customize.
enum TeamDashboardPreferences {
    static let showSectionKey = "godusage.teams.dashboard.showSection"
    static let membersShownKey = "godusage.teams.dashboard.membersShown"
    static let showProjectionKey = "godusage.teams.dashboard.showProjection"
    static let showChallengesKey = "godusage.teams.dashboard.showChallenges"
}

/// How many members the dashboard ranking shows before the caret. The rest unfold on click.
enum TeamMembersShown: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case five = 5
    case all = 0

    static let `default` = TeamMembersShown.two

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        default: "Top \(rawValue)"
        }
    }

    /// How many of `count` members show while the ranking is collapsed.
    func visibleCount(of count: Int) -> Int {
        self == .all ? count : min(count, rawValue)
    }
}

/// The Team card in Customize: whether the dashboard shows the Team section, how many members it
/// lists before the caret, and which extras sit around the ranking.
struct CustomizeTeamCard: View {
    @AppStorage(TeamDashboardPreferences.showSectionKey) private var showSection = true
    @AppStorage(TeamDashboardPreferences.membersShownKey) private var membersShown = TeamMembersShown.default.rawValue
    @AppStorage(TeamDashboardPreferences.showProjectionKey) private var showProjection = true
    @AppStorage(TeamDashboardPreferences.showChallengesKey) private var showChallenges = true

    private let density = DensitySetting.compact

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text("Team")
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                Spacer(minLength: 8)
                Toggle("", isOn: $showSection)
                    .settingsSwitchStyle()
                    .accessibilityLabel("Show Team on Dashboard")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)

            if showSection {
                Divider().padding(.leading, 12)
                row("Members Shown") {
                    Picker("", selection: $membersShown) {
                        ForEach(TeamMembersShown.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().padding(.leading, 12)
                row("Team Projection") {
                    Toggle("", isOn: $showProjection).settingsSwitchStyle()
                }
                Divider().padding(.leading, 12)
                row("Challenges") {
                    Toggle("", isOn: $showChallenges).settingsSwitchStyle()
                }
            }
        }
        .cardSurface()
        .animation(Motion.spring, value: showSection)
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}
