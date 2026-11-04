import Foundation

/// One enabled card's own daily history, as `WidgetDataStore.localTeamHistorySources()` reads it.
struct TeamHistorySource: Hashable, Sendable {
    var cardID: String
    var scope: UsageHistoryDescriptor.Scope
    var history: ProviderUsageHistory
    /// The plan the card detected (`ProviderSnapshot.plan`), e.g. "Max 20x".
    var plan: String? = nil
    /// The card's limiting quota window and its session, for the Plans report.
    var quotas: [TeamQuotaReading] = []
}

/// The body of `PUT /v1/devices/:id/usage`. Only totals leave the Mac: tokens and spend per day,
/// per provider family, and per model. No account ids, card names, project names, or logs.
struct TeamUsageUpload: Encodable, Hashable, Sendable {
    static let schema = "godusage.team-usage.v1"

    struct Model: Encodable, Hashable, Sendable {
        var model: String
        var tokens: Int
        var costUSD: Double?
    }

    struct Day: Encodable, Hashable, Sendable {
        var date: String
        var tokens: Int
        var costUSD: Double?
        var models: [Model]
    }

    struct DetectedPlan: Encodable, Hashable, Sendable {
        var provider: String
        var plan: String
    }

    /// One account's quota window (see `TeamQuotaLog`). `account` is an anonymous fingerprint.
    struct QuotaWindow: Encodable, Hashable, Sendable {
        var provider: String
        /// `limit` or `session`.
        var kind: String
        var account: String
        var endsAt: String
        var periodHours: Int
        var percent: Double
        var observedAt: String
        /// The share seen at the end of each local day, for weekly limit windows. Omitted otherwise.
        var days: [TeamQuotaLog.Day]?
        /// True when the account is named per Mac; omitted otherwise.
        var perDevice: Bool?
    }

    struct Provider: Encodable, Hashable, Sendable {
        var provider: String
        /// `device` sums across a user's Macs; `account` (already account-wide, like Cursor) counts once.
        var scope: String
        /// The account's anonymous fingerprint: on account scope, so the team counts an account
        /// several members share once (omitted when unknown); on a split entry, the account it is.
        var account: String?
        /// Set on one account sent apart from its provider's other accounts, because the user leaves
        /// it out of a team (see `ExcludedAccount`).
        var split: Bool?
        var days: [Day]

        /// Unique per upload: a provider comes once folded, plus once per split account.
        var entryKey: String { split == true ? "\(provider)|\(account ?? "")" : provider }
    }

    /// One account this Mac leaves out of one team. The server drops that account's split usage, its
    /// quota windows, and its ⚡ from the team. `account` matches the split entry's.
    struct ExcludedAccount: Encodable, Hashable, Sendable {
        var team: String
        var provider: String
        var account: String
    }

    var schema = Self.schema
    var deviceName: String
    /// The GodUsage version, shown to teammates beside "Updated 5m ago".
    var appVersion: String?
    /// The first day of this Mac's window. The server replaces this Mac's days from here on and
    /// keeps older ones, so history builds up beyond the 30-day window.
    var windowStart: String?
    /// Set on a partial upload: it carries only the provider-days that changed since the last
    /// accepted upload, and the server replaces just those (see `partial(from:to:)`).
    var partial: Bool?
    /// This Mac's calendar day, so the server dates a newly detected plan by the member's day.
    var localDay: String?
    /// The plan GodUsage detected per provider family, e.g. "Max 20x". The team's owners see it, to
    /// notice when the plan they pay for changed.
    var detectedPlans: [DetectedPlan] = []
    /// How much of each account's quota windows this Mac saw used. Always sent whole: the server
    /// replaces this Mac's windows with them.
    var quotaWindows: [QuotaWindow] = []
    /// Always sent whole: the server replaces this Mac's exclusions with them.
    var excludedAccounts: [ExcludedAccount] = []
    var providers: [Provider]

    static func instant(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Builds the upload from this Mac's cards. Account cards (`claude@ab12cd34`) fold into their
    /// family (`claude`): a leaderboard compares people per provider, not per login, and the
    /// account id must not leave the Mac. Days outside `dayKeys` are dropped.
    ///
    /// `excludedCards` maps a team id to the cards the user leaves out of it. Each card left out of
    /// any team goes up on its own instead (`split`, named by `accountKey`), so the server can drop it
    /// from those teams; the upload lists the exclusions in `excludedAccounts`.
    static func make(
        sources: [TeamHistorySource],
        deviceName: String,
        dayKeys: Set<String>,
        appVersion: String = AppInfo.version,
        excludedCards: [String: Set<String>] = [:],
        accountKey: (TeamHistorySource) -> String = { $0.history.accountKey ?? $0.cardID }
    ) -> TeamUsageUpload {
        struct DayAccumulator {
            var tokens = 0
            var cost: Double?
            var models: [String: (name: String, tokens: Int, cost: Double?)] = [:]
        }
        struct Entry {
            var family: String
            var scope: UsageHistoryDescriptor.Scope
            var account: String?
            var split: Bool
            var days: [String: DayAccumulator] = [:]
        }
        let splitCards = excludedCards.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var entries: [String: Entry] = [:]
        var splitKeys: [String: String] = [:]

        for source in sources {
            let family = ProviderAccountID.family(of: source.cardID)
            let isSplit = splitCards.contains(source.cardID)
            let key: String
            var entry: Entry
            if isSplit {
                let account = accountKey(source)
                splitKeys[source.cardID] = account
                key = "\(family)|\(account)"
                entry = entries[key] ?? Entry(family: family, scope: source.scope, account: account, split: true)
            } else {
                key = family
                entry = entries[key] ?? Entry(family: family, scope: source.scope, account: nil, split: false)
                // A family is account-wide if any of its cards is, so it is never summed across Macs.
                if source.scope == .accountWide {
                    entry.scope = .accountWide
                    entry.account = entry.account ?? source.history.accountKey
                }
            }

            for day in source.history.series.daily where dayKeys.contains(day.date) {
                var accumulator = entry.days[day.date] ?? DayAccumulator()
                accumulator.tokens += day.totalTokens
                accumulator.cost = add(accumulator.cost, day.costUSD)
                entry.days[day.date] = accumulator
            }
            for day in source.history.modelUsage?.daily ?? [] where dayKeys.contains(day.date) {
                var accumulator = entry.days[day.date] ?? DayAccumulator()
                for model in day.models {
                    // The server treats model names case-insensitively, so merge them the same way.
                    let key = model.model.lowercased()
                    var existing = accumulator.models[key] ?? (model.model, 0, nil)
                    existing.tokens += model.totalTokens
                    existing.cost = add(existing.cost, model.costUSD)
                    accumulator.models[key] = existing
                }
                entry.days[day.date] = accumulator
            }
            entries[key] = entry
        }

        let providers = entries.keys.sorted().compactMap { key -> Provider? in
            guard let entry = entries[key] else { return nil }
            let days = entry.days.keys.sorted().compactMap { date -> Day? in
                guard let day = entry.days[date] else { return nil }
                let models = day.models.values
                    .filter { $0.tokens > 0 || ($0.cost ?? 0) > 0 }
                    .sorted { $0.name < $1.name }
                    .map { Model(model: $0.name, tokens: $0.tokens, costUSD: $0.cost) }
                return Day(date: date, tokens: day.tokens, costUSD: day.cost, models: models)
            }
            guard !days.isEmpty else { return nil }
            let isAccountWide = entry.scope == .accountWide
            return Provider(
                provider: entry.family,
                scope: isAccountWide ? "account" : "device",
                account: isAccountWide || entry.split ? entry.account : nil,
                split: entry.split ? true : nil,
                days: days
            )
        }
        // A family's plan is its first card's (by id) that detected one, cards counted in every team
        // first (the plan a team pays for); the plain card sorts first.
        var plans: [String: String] = [:]
        for source in sources.sorted(by: { (splitCards.contains($0.cardID) ? 1 : 0, $0.cardID) < (splitCards.contains($1.cardID) ? 1 : 0, $1.cardID) }) {
            let family = ProviderAccountID.family(of: source.cardID)
            if plans[family] == nil, let plan = source.plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
                plans[family] = String(plan.prefix(60))
            }
        }
        let excluded = excludedCards.keys.sorted().flatMap { team in
            (excludedCards[team] ?? []).sorted().compactMap { cardID in
                splitKeys[cardID].map { ExcludedAccount(team: team, provider: ProviderAccountID.family(of: cardID), account: $0) }
            }
        }
        return TeamUsageUpload(
            deviceName: deviceName,
            appVersion: appVersion,
            windowStart: dayKeys.min(),
            localDay: dayKeys.max(),
            detectedPlans: plans.keys.sorted().map { DetectedPlan(provider: $0, plan: plans[$0]!) },
            excludedAccounts: Array(Set(excluded)).sorted { ($0.team, $0.account) < ($1.team, $1.account) },
            providers: providers
        )
    }

    /// The provider-days of `current` that differ from `previous` (the last body the server accepted),
    /// as a partial upload, so the server replaces a day or two instead of re-reading the whole
    /// window (the teams database is billed per row read). Nil when only a full upload is right:
    /// a provider-day in the window disappeared, or a provider changed scope or account.
    static func partial(from previous: TeamUsageUpload, to current: TeamUsageUpload) -> TeamUsageUpload? {
        let windowStart = current.windowStart ?? ""
        let currentProviders = Dictionary(current.providers.map { ($0.entryKey, $0) }, uniquingKeysWith: { first, _ in first })
        var previousDays: [String: [String: Day]] = [:]
        for old in previous.providers {
            let days = old.days.filter { $0.date >= windowStart }
            previousDays[old.entryKey] = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            guard !days.isEmpty else { continue }
            guard let new = currentProviders[old.entryKey], new.scope == old.scope, new.account == old.account else { return nil }
            let dates = Set(new.days.map(\.date))
            if days.contains(where: { !dates.contains($0.date) }) { return nil }
        }
        var upload = current
        upload.windowStart = nil
        upload.partial = true
        upload.providers = current.providers.compactMap { provider in
            let old = previousDays[provider.entryKey] ?? [:]
            var changed = provider
            changed.days = provider.days.filter { old[$0.date] != $0 }
            return changed.days.isEmpty ? nil : changed
        }
        return upload
    }

    /// Unknown plus a known cost stays the known part: spend tiles also count only priced usage.
    private static func add(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case let (value?, nil), let (nil, value?): value
        case let (left?, right?): left + right
        }
    }
}
