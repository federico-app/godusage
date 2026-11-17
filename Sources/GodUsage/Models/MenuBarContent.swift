import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values. The renderers consume this: `groups` drives the Text style (one segment per pinned provider,
/// each with its 1–2 pinned metrics), `bars` drives the Bars style (the first four bounded metrics — any
/// with a fill, not just percentages — in order). `isEmpty` means render the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session" (VoiceOver)
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool
        /// Spent or projected to run out before the reset (`MeterState.showsFlame`): the Text strip
        /// draws the value in orange, the Bars glyph draws its bar in orange.
        var isOverPace: Bool = false
        /// The dimmed "S"/"W" in front of a stacked value (`MenuBarMetricLabel`).
        var prefix: String? = nil
        /// What the Text strip draws (`MenuBarValueText`); nil draws `value` plainly.
        var spans: [MenuBarSpan]? = nil

        var displaySpans: [MenuBarSpan] { spans ?? [MenuBarSpan(value)] }
        var displayText: String { displaySpans.map(\.text).joined() }

        /// Same drawing in the Text strip: everything but the bar fill.
        func rendersSameText(as other: Metric) -> Bool {
            id == other.id && label == other.label && value == other.value && hasData == other.hasData
                && isOverPace == other.isOverPace && prefix == other.prefix && displaySpans == other.displaySpans
        }
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
        var isExhausted: Bool = false
        var loginRequired: Bool = false
        /// The dot on the icon (`MenuBarBadge.decide`).
        var badge: MenuBarBadge? = nil
        /// An exhausted account's time to its reset, dimmed beside the faded icon ("↻2d 4h").
        var resetText: String? = nil
        /// Replaces the display name in the hover tooltip and VoiceOver (the team segment's share).
        var detail: String? = nil
        var isDimmed: Bool { isExhausted || loginRequired }
        var toolTip: String { detail ?? displayName }
    }

    /// Provider groups for the Text style, in Customize order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders. An exhausted weekly
    /// allowance or a login to renew keeps an icon-only group, explicitly marked so renderers can dim it.
    let groups: [Group]
    /// Bounded metrics (those with a fill) for the Bars style, flattened in order and capped to four.
    let bars: [Metric]

    /// Nothing is pinned, every pinned provider is disabled, or no pinned metric has data yet — the
    /// menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// Whether two contents render identically under `style` — the strip cache's memo predicate.
    /// The Text style draws each metric's text but never its `fraction`. Comparing only what the
    /// style draws (plus the group text `accessibilityText` bakes into the cached image) keeps a
    /// refresh that nudged an underlying fraction behind an unchanged rounded value (still "41%")
    /// from paying a full re-render: N+1 `ImageRenderer` passes plus a per-pixel bounds scan.
    func isRenderEquivalent(to other: MenuBarContent, style: MenuBarStyle) -> Bool {
        // Both styles bake `accessibilityText` — group names, labels, values — into the image.
        guard groups.count == other.groups.count else { return false }
        let groupTextMatches = zip(groups, other.groups).allSatisfy { mine, theirs in
            mine.providerID == theirs.providerID
                && mine.displayName == theirs.displayName
                && mine.icon == theirs.icon
                && mine.isExhausted == theirs.isExhausted
                && mine.loginRequired == theirs.loginRequired
                && mine.badge == theirs.badge
                && mine.resetText == theirs.resetText
                && mine.detail == theirs.detail
                && mine.metrics.count == theirs.metrics.count
                && zip(mine.metrics, theirs.metrics).allSatisfy { $0.rendersSameText(as: $1) }
        }
        guard groupTextMatches else { return false }
        switch style {
        case .text:
            return true
        case .bars:
            guard bars.count == other.bars.count else { return false }
            return zip(bars, other.bars).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.fraction == rhs.fraction && lhs.hasData == rhs.hasData
                    && lhs.isOverPace == rhs.isOverPace
            }
        }
    }

    /// Whether any part of the strip is drawn in color (orange, green, or a badge), so the image
    /// can't be a template.
    func needsColor(style: MenuBarStyle) -> Bool {
        let shownGroups = style == .text ? groups : groups.filter(\.isDimmed)
        if shownGroups.contains(where: { $0.badge != nil }) { return true }
        switch style {
        case .text:
            return groups.contains { $0.metrics.contains { $0.displaySpans.contains(where: \.tone.isColored) } }
        case .bars:
            return bars.contains(where: \.isOverPace)
        }
    }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let name = group.detail ?? group.displayName
            if group.loginRequired { return "\(name) Login Required" }
            if group.isExhausted {
                return "\(name) Usage Exhausted" + (group.resetText.map { ", Resets \($0)" } ?? "")
            }
            let metrics = group.metrics
                .map { "\($0.label) \($0.displayText)\($0.isOverPace ? " Over Pace" : "")" }
                .joined(separator: ", ")
            let badge = group.badge == .useNow ? ", Use This Now" : ""
            return "\(name) \(metrics)\(badge)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Max bars the compact style renders — the Tauri edition's tray cap, kept so the glyph stays
    /// legible at menu-bar size.
    static let maxBars = 4
    /// The Text strip has room for two stacked values per provider.
    static let maxMetricsPerGroup = 2

    /// Resolve provider groups into menu-bar content. `groups` is `LayoutStore.menuBarGroups`
    /// (ordered, disabled providers excluded, providers without stars carry no metrics); `data`
    /// resolves each descriptor to its live `WidgetData` (i.e. `WidgetDataStore.data(for:)`), so the
    /// values follow the global meter style just like the dashboard tiles.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now. A provider whose login needs
    /// renewing shows its faded icon whether or not it has stars.
    /// `title` resolves each provider's card title (the VoiceOver summary is a human-facing name, so
    /// the caller passes the account-registry resolver); defaults to the baked derived name.
    /// `switchTargets` are the accounts a "Switch to …" suggestion recommends (green dot).
    static func build(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        title: (Provider) -> String = { $0.displayName },
        quotaDescriptors: (String) -> [WidgetDescriptor] = { _ in [] },
        loginRequired: (String) -> Bool = { _ in false },
        switchTargets: Set<String> = [],
        now: Date = Date()
    ) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let needsLogin = loginRequired(group.provider.id)
            // A provider with no stars shows only to say its login needs renewing.
            guard !group.metrics.isEmpty || needsLogin else { return nil }
            // Applicability can change after dormant pins were retained. Resolve live values first so
            // no-data pins consume no room, then reapply the renderer's two-row invariant without
            // destructively changing the user's saved preferences.
            let metrics = Array(
                group.metrics
                    .map { resolve($0, data($0), now: now) }
                    .filter(\.hasData)
                    .prefix(maxMetricsPerGroup)
            )
            let quotas = quotaDescriptors(group.provider.id) + group.metrics
            let exhausted = !group.metrics.isEmpty && WeeklyQuotaVisibility.menuBarIsExhausted(
                descriptors: quotas,
                pinned: group.metrics.filter { descriptor in metrics.contains { $0.id == descriptor.id } },
                data: data
            )
            guard !metrics.isEmpty || needsLogin || exhausted else { return nil }
            let resetText = exhausted && !needsLogin
                ? WeeklyQuotaVisibility.menuBarExhaustedResetsAt(descriptors: quotas, data: data)
                    .flatMap { MenuBarValueText.resetText($0.timeIntervalSince(now)) }
                : nil
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: title(group.provider),
                icon: group.provider.icon,
                metrics: exhausted || needsLogin ? [] : metrics,
                isExhausted: exhausted,
                loginRequired: needsLogin,
                badge: MenuBarBadge.decide(
                    loginRequired: needsLogin, isSwitchTarget: switchTargets.contains(group.provider.id)
                ),
                resetText: resetText
            )
        }
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: resolvedGroups, bars: Array(bars))
    }

    /// The team segment: rank, movement and spend over your plan's pace (`MenuBarTeamSegment`).
    static func teamGroup(
        standing: MenuBarTeamSegment.Standing, paces: [LivePace], now: Date
    ) -> MenuBarContent.Group {
        var metrics = [
            MenuBarContent.Metric(
                id: "team.rank", label: "Rank", value: "#\(standing.rank)", fraction: 0, isBounded: false,
                hasData: true, spans: MenuBarTeamSegment.topLine(standing)
            ),
        ]
        if let bottom = MenuBarTeamSegment.bottomLine(standing: standing, paces: paces, now: now) {
            metrics.append(MenuBarContent.Metric(
                id: "team.pace", label: "Pace", value: bottom.map(\.text).joined(), fraction: 0,
                isBounded: false, hasData: true, spans: bottom
            ))
        }
        return MenuBarContent.Group(
            providerID: TeamsStore.menuBarGroupID,
            displayName: "Team",
            icon: .providerMark(TeamsStore.menuBarGroupID),
            metrics: metrics,
            detail: MenuBarTeamSegment.detail(standing)
        )
    }

    private static func resolve(_ descriptor: WidgetDescriptor, _ data: WidgetData, now: Date) -> MenuBarContent.Metric {
        let prefix = MenuBarMetricLabel.prefix(for: descriptor)
        let value = data.menuBarValue
        return MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: value,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData,
            isOverPace: data.meterState(now: now).showsFlame,
            prefix: prefix,
            spans: MenuBarValueText.spans(value: value, prefix: prefix, data: data, now: now)
        )
    }

    /// Tray-only label shortening (the dashboard keeps the full names): the long time-window metrics
    /// collapse to a single letter so a two-metric stack stays narrow. Unknown labels pass through.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        default: return metricLabel
        }
    }
}
