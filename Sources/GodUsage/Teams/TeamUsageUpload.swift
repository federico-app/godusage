import Foundation

/// One enabled card's own daily history, as `WidgetDataStore.localTeamHistorySources()` reads it.
struct TeamHistorySource: Hashable, Sendable {
    var cardID: String
    var scope: UsageHistoryDescriptor.Scope
    var history: ProviderUsageHistory
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

    struct Provider: Encodable, Hashable, Sendable {
        var provider: String
        /// `device` sums across a user's Macs; `account` (already account-wide, like Cursor) counts once.
        var scope: String
        /// Account-scope only: the account's anonymous fingerprint, so the team counts an account
        /// several members share once. Omitted when unknown.
        var account: String?
        var days: [Day]
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
    var providers: [Provider]

    /// Builds the upload from this Mac's cards. Account cards (`claude@ab12cd34`) fold into their
    /// family (`claude`): a leaderboard compares people per provider, not per login, and the
    /// account id must not leave the Mac. Days outside `dayKeys` are dropped.
    static func make(
        sources: [TeamHistorySource],
        deviceName: String,
        dayKeys: Set<String>,
        appVersion: String = AppInfo.version
    ) -> TeamUsageUpload {
        struct DayAccumulator {
            var tokens = 0
            var cost: Double?
            var models: [String: (name: String, tokens: Int, cost: Double?)] = [:]
        }
        var families: [String: (scope: UsageHistoryDescriptor.Scope, account: String?, days: [String: DayAccumulator])] = [:]

        for source in sources {
            let family = String(source.cardID.split(separator: "@", maxSplits: 1).first ?? Substring(source.cardID))
            var entry = families[family] ?? (source.scope, nil, [:])
            // A family is account-wide if any of its cards is, so it is never summed across Macs.
            if source.scope == .accountWide {
                entry.scope = .accountWide
                entry.account = entry.account ?? source.history.accountKey
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
            families[family] = entry
        }

        let providers = families.keys.sorted().compactMap { family -> Provider? in
            guard let entry = families[family] else { return nil }
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
            return Provider(provider: family, scope: isAccountWide ? "account" : "device", account: isAccountWide ? entry.account : nil, days: days)
        }
        return TeamUsageUpload(deviceName: deviceName, appVersion: appVersion, windowStart: dayKeys.min(), providers: providers)
    }

    /// The provider-days of `current` that differ from `previous` (the last body the server accepted),
    /// as a partial upload, so the server replaces a day or two instead of re-reading the whole
    /// window (the teams database is billed per row read). Nil when only a full upload is right:
    /// a provider-day in the window disappeared, or a provider changed scope or account.
    static func partial(from previous: TeamUsageUpload, to current: TeamUsageUpload) -> TeamUsageUpload? {
        let windowStart = current.windowStart ?? ""
        let currentProviders = Dictionary(current.providers.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        var previousDays: [String: [String: Day]] = [:]
        for old in previous.providers {
            let days = old.days.filter { $0.date >= windowStart }
            previousDays[old.provider] = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            guard !days.isEmpty else { continue }
            guard let new = currentProviders[old.provider], new.scope == old.scope, new.account == old.account else { return nil }
            let dates = Set(new.days.map(\.date))
            if days.contains(where: { !dates.contains($0.date) }) { return nil }
        }
        var upload = current
        upload.windowStart = nil
        upload.partial = true
        upload.providers = current.providers.compactMap { provider in
            let old = previousDays[provider.provider] ?? [:]
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
