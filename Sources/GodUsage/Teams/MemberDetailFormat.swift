import Foundation

/// The words and numbers of a member's detail on the dashboard (`TeamMemberDetail`): the four tiles,
/// the gold chips, the provider and model shares, who reacted, and the footer. Pure, so it is tested.
enum MemberDetailFormat {
    /// One tile of the 2×2 grid: a small uppercase label, a big number, one line of context.
    struct Tile: Equatable {
        var label: String
        var value: String
        var context: String
        /// The value reads in the orange notice color (a member spending fast).
        var isNotice = false
        /// The full sentence for VoiceOver.
        var accessibilityLabel: String
    }

    /// A gold chip under the name: a symbol, a short text, and the full sentence for the tooltip.
    struct Award: Equatable {
        var symbol: String
        var title: String
        var detail: String
    }

    /// One row of the providers or models list, and its segment of the stacked bar.
    struct Share: Equatable, Identifiable {
        /// `provider` for a provider, `provider/model` for a model, "other" for the rest.
        var id: String
        var title: String
        /// Nil for the "Other" row.
        var provider: String?
        var totals: UsageTotals
        /// 0–1 of the list's total.
        var fraction: Double
    }

    // MARK: - Tiles

    /// LAST HOUR: "+$164.15" (orange while they have a momentum level) with "Fast · most in the team",
    /// or "Quiet" without spend in the last hour.
    static func lastHourTile(_ momentum: TeamMomentum?) -> Tile {
        guard let momentum, momentum.lastHourUSD > 0 else {
            return Tile(
                label: lastHourLabel, value: Formatters.currency(0),
                context: String(localized: "Quiet", comment: "Member detail, LAST HOUR tile: no spend in the last hour"),
                accessibilityLabel: String(localized: "Last hour: no spend", comment: "Member detail, LAST HOUR tile, for VoiceOver")
            )
        }
        return Tile(
            label: lastHourLabel,
            value: "+\(Formatters.currency(momentum.lastHourUSD))",
            context: momentumContext(momentum),
            isNotice: momentum.level > 0,
            accessibilityLabel: momentumExplanation(momentum)
        )
    }

    private static var lastHourLabel: String {
        String(localized: "LAST HOUR", comment: "Member detail: uppercase tile label, spend in the last hour")
    }

    /// "Fast · most in the team": the level's name, then "most in the team" only when they spent the
    /// most in the last hour. "Normal pace" for spend that earned no level.
    static func momentumContext(_ momentum: TeamMomentum) -> String {
        guard momentum.level > 0 else { return String(localized: "Normal pace", comment: "Member detail, LAST HOUR tile: spend that earned no momentum level") }
        let name = levelName(momentum.level)
        guard (momentum.reasons ?? []).contains("top") else { return name }
        return String(localized: "\(name) · most in the team", comment: "Member detail, LAST HOUR tile: a momentum level (Fast), and they spent the most in the team")
    }

    /// Level 1, 2, 3 of the momentum, in a word or two.
    static func levelName(_ level: Int) -> String {
        switch min(level, 3) {
        case ...1: String(localized: "Picking up", comment: "Member momentum level 1 of 3: spending is picking up")
        case 2: String(localized: "Fast", comment: "Member momentum level 2 of 3: spending fast")
        default: String(localized: "Very fast", comment: "Member momentum level 3 of 3: spending very fast")
        }
    }

    /// "$18.40 in the last hour · spending fast, level 2 of 3: over $5, more than twice their usual
    /// hour ($3.10), the most in the team". The full story, for VoiceOver.
    static func momentumExplanation(_ momentum: TeamMomentum) -> String {
        let spent = String(localized: "\(Formatters.currency(momentum.lastHourUSD)) in the last hour")
        let reasons = (momentum.reasons ?? []).compactMap { reason -> String? in
            switch reason {
            case "fast": String(localized: "over $5", comment: "Member momentum reason: spent over $5 in the last hour")
            case "self": momentum.typicalHourUSD.map {
                    String(localized: "more than twice their usual hour (\(Formatters.currency($0)))", comment: "Member momentum reason; the value is their typical hour's spend")
                } ?? String(localized: "more than twice their usual hour", comment: "Member momentum reason")
            case "top": String(localized: "the most in the team", comment: "Member momentum reason: spent the most in the team in the last hour")
            default: nil
            }
        }
        guard momentum.level > 0 else { return spent }
        let levelNumber = min(momentum.level, 3)
        let level = String(localized: "\(spent) · spending fast, level \(levelNumber) of 3", comment: "Member momentum for VoiceOver: the spend in the last hour, then the level")
        return reasons.isEmpty ? level : "\(level): \(reasons.joined(separator: ", "))"
    }

    /// NOVEMBER PACE: the month's projection in whole dollars, with "13 days left" ("Last day" on it).
    static func paceTile(_ projection: TeamProjection) -> Tile {
        let value = Formatters.currency(projection.projected, fractionDigits: 0)
        let left = projection.daysLeft == 1 ? String(localized: "1 day left", comment: "Member detail, month projection tile")
            : projection.daysLeft > 0 ? String(localized: "\(projection.daysLeft) days left") : String(localized: "Last day")
        let month = projection.monthName
        let upperMonth = month.uppercased(with: AppLocale.current)
        let lowerLeft = left.lowercased(with: AppLocale.current)
        return Tile(
            label: String(localized: "\(upperMonth) PACE", comment: "Member detail: uppercase tile label, the month's spend projection, e.g. NOVEMBER PACE"),
            value: value,
            context: left,
            accessibilityLabel: String(localized: "On pace for \(value) in \(month), \(lowerLeft)", comment: "Member detail, month projection for VoiceOver: a dollar amount, the month, the days left")
        )
    }

    /// EFFICIENCY: "$0.39" per million tokens; nil without tokens.
    static func efficiencyTile(_ totals: UsageTotals) -> Tile? {
        guard let rate = totals.costPerMillionTokens else { return nil }
        let value = Formatters.currency(rate)
        return Tile(
            label: String(localized: "EFFICIENCY", comment: "Member detail: uppercase tile label, dollars per million tokens"),
            value: value,
            context: String(localized: "per million tokens", comment: "Member detail, EFFICIENCY tile"),
            accessibilityLabel: String(localized: "Efficiency: \(value) per million tokens", comment: "Member detail, EFFICIENCY tile for VoiceOver")
        )
    }

    /// PLACE: "1st of 2" with its movement ("Same as yesterday").
    static func placeTile(rank: Int, of count: Int, rankChange: Int?, hasUsage: Bool, range: StatsRange) -> Tile {
        let place = placeText(rank: rank, of: count)
        let movement = movementText(rankChange: rankChange, hasUsage: hasUsage, range: range)
        return Tile(
            label: String(localized: "PLACE", comment: "Member detail: uppercase tile label, the member's rank"),
            value: place,
            context: movement ?? " ",
            accessibilityLabel: movement.map { "\(place), \($0.lowercased(with: AppLocale.current))" } ?? place
        )
    }

    /// "1st of 6".
    static func placeText(rank: Int, of count: Int) -> String {
        let place = ordinal(rank)
        return String(localized: "\(place) of \(count)", comment: "Member detail, PLACE tile: an ordinal rank and the member count, e.g. 1st of 6")
    }

    /// "Same as yesterday", "Up 2 since yesterday", "Down 1 since yesterday", or "New" for a member
    /// with usage now and none in the period before. Nil on the Year board, which has no movement.
    static func movementText(rankChange: Int?, hasUsage: Bool, range: StatsRange) -> String? {
        if range == .year { return nil }
        guard let change = rankChange else { return hasUsage ? String(localized: "New") : nil }
        let places = abs(change)
        // One whole sentence per range, so each language words the period its own way.
        switch range {
        case .today, .year:
            if change == 0 { return String(localized: "Same as yesterday", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since yesterday", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since yesterday", comment: "Member rank movement: places lost")
        case .week:
            if change == 0 { return String(localized: "Same as the previous 7 days", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since the previous 7 days", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since the previous 7 days", comment: "Member rank movement: places lost")
        case .month:
            if change == 0 { return String(localized: "Same as the previous 30 days", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since the previous 30 days", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since the previous 30 days", comment: "Member rank movement: places lost")
        case .monthToDate:
            if change == 0 { return String(localized: "Same as the same days last month", comment: "Member rank movement") }
            return change > 0 ? String(localized: "Up \(places) since the same days last month", comment: "Member rank movement: places gained")
                : String(localized: "Down \(places) since the same days last month", comment: "Member rank movement: places lost")
        }
    }

    /// "1st" / "1º", in the app's language.
    static func ordinal(_ rank: Int, locale: Locale = AppLocale.current) -> String {
        AppLocale.ordinal(rank, locale: locale)
    }

    // MARK: - Chips

    /// The gold chips under the name: today's top spender, then last month's champion.
    static func awards(isTopToday: Bool, champion: TeamChampion?) -> [Award] {
        var awards: [Award] = []
        if isTopToday {
            awards.append(Award(
                symbol: "crown.fill",
                title: String(localized: "Top today", comment: "Member detail chip: today's top spender"),
                detail: String(localized: "Top spender today")
            ))
        }
        if let champion {
            awards.append(Award(
                symbol: "trophy.fill",
                title: String(localized: "\(champion.monthName) champion"),
                detail: String(localized: "\(champion.monthLabel) champion: top spender of the month", comment: "Member detail chip tooltip; the value is a month and year")
            ))
        }
        return awards
    }

    // MARK: - Shares

    /// "MODELS TODAY", "PROVIDERS 7 DAYS". `noun` is a catalog key, so literal call sites get extracted.
    static func listTitle(_ noun: LocalizedStringResource, range: StatsRange) -> String {
        "\(String(localized: noun)) \(range.label)".uppercased(with: AppLocale.current)
    }

    /// The member's providers with usage, largest first, as shares of their total. Empty with fewer
    /// than two: a single provider equals the total above it.
    static func providerShares(_ providers: [TeamStats.ProviderTotals], metric: TeamMetric, providerName: (String) -> String) -> [Share] {
        let items = providers.map { Share(id: $0.provider, title: providerName($0.provider), provider: $0.provider, totals: $0.totals, fraction: 0) }
        let shares = self.shares(items, metric: metric, limit: .max)
        return shares.count > 1 ? shares : []
    }

    /// The member's models with usage in `stats`, largest first, as shares of their total: the
    /// `limit` largest, then one "Other" row for the rest.
    static func modelShares(_ models: [TeamStats.Model], userID: String, metric: TeamMetric, limit: Int = 5) -> [Share] {
        let items = models.compactMap { model -> Share? in
            guard let mine = model.members.first(where: { $0.userID == userID }) else { return nil }
            return Share(id: model.id, title: model.model, provider: model.provider, totals: mine.totals, fraction: 0)
        }
        return shares(items, metric: metric, limit: limit)
    }

    /// What a share is measured in: the metric itself, except Cost/MTok, whose rates don't add up,
    /// where shares follow spend.
    static func weight(_ totals: UsageTotals, metric: TeamMetric) -> Double {
        metric == .costPerMtok ? totals.costUSD : metric.value(totals)
    }

    static func shares(_ items: [Share], metric: TeamMetric, limit: Int) -> [Share] {
        let used = items.filter { weight($0.totals, metric: metric) > 0 }
            .sorted { weight($0.totals, metric: metric) > weight($1.totals, metric: metric) }
        let total = used.reduce(0) { $0 + weight($1.totals, metric: metric) }
        guard total > 0 else { return [] }
        var shown = used.prefix(limit).map { item -> Share in
            var share = item
            share.fraction = weight(item.totals, metric: metric) / total
            return share
        }
        let rest = used.dropFirst(limit)
        if !rest.isEmpty {
            let totals = rest.reduce(UsageTotals(tokens: 0, costUSD: 0)) {
                UsageTotals(tokens: $0.tokens + $1.totals.tokens, costUSD: $0.costUSD + $1.totals.costUSD)
            }
            shown.append(Share(id: "other", title: String(localized: "\(rest.count) more", comment: "Member detail: the row for every other model"), provider: nil, totals: totals, fraction: weight(totals, metric: metric) / total))
        }
        return shown
    }

    /// "97%", "<1%" for a sliver.
    static func percentText(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.005 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Reactions and footer

    /// Who reacted today: a short line of first names ("Matteo, Daniele", "You" for the viewer) and
    /// the full list by reaction for the tooltip ("🔥 Matteo Rossi, Daniele Bianchi"). Nil when nobody
    /// did, or the server doesn't say who.
    static func reactionGivers(_ reactions: MemberReactions, names: [String: String], me: String?) -> (summary: String, detail: String)? {
        var short: [String] = []
        var seen = Set<String>()
        var lines: [String] = []
        for reaction in TeamReaction.allCases {
            let givers = reactions.from?[reaction.rawValue] ?? []
            guard !givers.isEmpty else { continue }
            let full = givers.map { $0 == me ? String(localized: "You") : names[$0] ?? String(localized: "A former member", comment: "A reaction giver who left the team") }
            lines.append("\(reaction.emoji) \(full.joined(separator: ", "))")
            for (id, name) in zip(givers, full) where seen.insert(id).inserted {
                short.append(id == me ? String(localized: "You") : String(name.split(separator: " ").first ?? Substring(name)))
            }
        }
        guard !short.isEmpty else { return nil }
        return (short.joined(separator: ", "), lines.joined(separator: "\n"))
    }

    /// "Updated 5m ago · v1.3.3-dev"; the version is left out when it is outdated, since the orange
    /// chip next to it shows it. "Not synced yet" before any upload.
    static func footerText(lastSyncAt: String?, appVersion: String?, isOutdated: Bool, now: Date) -> String {
        let version = isOutdated ? nil : appVersion
        if let note = TeamsFormat.syncNote(lastSyncAt, now: now, appVersion: version) { return note.text }
        guard let version else { return String(localized: "Not synced yet", comment: "Member detail footer: the member's Macs never uploaded") }
        let label = TeamsFormat.versionLabel(version)
        return String(localized: "Not synced yet · \(label)", comment: "Member detail footer: never uploaded, then the app version")
    }
}

extension TeamsFormat {
    /// "November" / "novembre" for month 11, in the app's language whatever the Mac's.
    static func monthName(_ month: Int, locale: Locale = AppLocale.current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.standaloneMonthSymbols ?? []
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : "\(month)"
    }
}
