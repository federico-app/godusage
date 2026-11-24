import SwiftUI

/// A member spending fast right now: a bolt and a three-step meter filled up to the momentum level
/// (1–3), in one fixed-width orange chip. Nothing at level 0.
struct MomentumBolts: View {
    let momentum: TeamMomentum?

    var body: some View {
        if let level = momentum?.level, level > 0 {
            let filled = min(level, 3)
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(1...3, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 3, height: CGFloat(2 + 2 * step))
                            .opacity(step <= filled ? 1 : 0.25)
                    }
                }
            }
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.noticeColor.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Spending fast: level \(filled) of 3")
        }
    }
}

/// The line under a member's bar: a green live dot and "+$12.40 last hour" while they spent
/// something in the last hour, otherwise when they last synced, plus their version
/// only when it is outdated. The member's detail explains everything in full.
struct MemberStatusNote: View {
    let member: TeamStats.Member
    let momentum: TeamMomentum?
    let newestVersion: String?

    var body: some View {
        if let momentum, TeamLeaderboardLayout.isActive(momentum) {
            HStack(spacing: 5) {
                LiveDot()
                Text("+\(Formatters.currency(momentum.lastHourUSD)) last hour", comment: "Spend in the last hour, under a member's bar.")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Active now: \(Formatters.currency(momentum.lastHourUSD)) in the last hour")
        } else {
            TeamSyncNote(member: member, newestVersion: newestVersion)
        }
    }
}

/// A small green dot that pulses gently: the member is spending right now. Still with Reduce Motion,
/// and still while its host is off screen.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveAnimationsActive) private var hostVisible

    var body: some View {
        // A repeating symbol effect is not free: SwiftUI renders every frame of it through the hosting
        // view, and the popover's tree survives `orderOut`. Left running behind a closed popover it kept
        // the main thread busy at ~50–60% CPU, so it only runs while the host is on screen.
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(Theme.positive)
            .symbolEffect(.pulse, options: .repeating, isActive: Self.pulses(hostVisible: hostVisible, reduceMotion: reduceMotion))
            .accessibilityHidden(true)
    }

    static func pulses(hostVisible: Bool, reduceMotion: Bool) -> Bool {
        hostVisible && !reduceMotion
    }
}

/// Whether the view's host window is on screen, for repeating animations that must stop when it isn't.
/// Default `true`: a window that is torn down on close (the Teams window) needs nothing. The popover,
/// whose tree outlives `orderOut`, sets it from `PopoverTransparencyStore.popoverShown`.
private struct LiveAnimationsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var liveAnimationsActive: Bool {
        get { self[LiveAnimationsActiveKey.self] }
        set { self[LiveAnimationsActiveKey.self] = newValue }
    }
}

extension TeamsFormat {
    /// The newest GodUsage version among the members' latest uploads.
    static func newestVersion(_ members: [TeamStats.Member]) -> String? {
        members.compactMap(\.appVersion).max { versionParts($0).lexicographicallyPrecedes(versionParts($1)) }
    }

    /// Whether `version` is older than `newest`, comparing the leading numbers ("1.0.9" < "1.0.10";
    /// a "-dev.642" suffix is ignored). False when either is unknown.
    static func isOutdated(_ version: String?, newest: String?) -> Bool {
        guard let version, let newest else { return false }
        return versionParts(version).lexicographicallyPrecedes(versionParts(newest))
    }

    private static func versionParts(_ version: String) -> [Int] {
        let numeric = version.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }
}
