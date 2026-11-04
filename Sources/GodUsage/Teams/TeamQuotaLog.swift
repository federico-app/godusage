import Foundation

/// One reading of an account's quota window, from a card's latest snapshot. The limiting window
/// (Claude's and Codex's weekly window, Cursor's billing cycle) is what the Plans report compares
/// with what a plan costs; Claude's and Codex's 5-hour session shows how often a plan runs short.
struct TeamQuotaReading: Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case limit, session
    }

    var provider: String
    var cardID: String
    /// A fingerprint that names the account the same on every Mac (Cursor's), when there is one.
    var accountKey: String?
    var endsAt: Date
    var periodHours: Int
    /// Share of the window used, 0–100 (more when over the limit).
    var percent: Double
    var observedAt: Date
    var kind: Kind = .limit

    /// The quota row each provider's plan is limited by. Other providers send none.
    static let limitingLabels = ["claude": "Weekly", "codex": "Weekly", "cursor": "Total usage"]
    /// The 5-hour session row of the providers that have one.
    static let sessionLabels = ["claude": "Session", "codex": "Session"]

    /// The card's limiting window and its session, when it reports them.
    static func readings(cardID: String, snapshot: ProviderSnapshot, accountKey: String?) -> [TeamQuotaReading] {
        [make(cardID: cardID, snapshot: snapshot, accountKey: accountKey), makeSession(cardID: cardID, snapshot: snapshot, accountKey: accountKey)]
            .compactMap { $0 }
    }

    static func make(cardID: String, snapshot: ProviderSnapshot, accountKey: String?) -> TeamQuotaReading? {
        let provider = ProviderAccountID.family(of: cardID)
        guard let label = limitingLabels[provider] else { return nil }
        return reading(label: label, kind: .limit, provider: provider, cardID: cardID, snapshot: snapshot, accountKey: accountKey)
    }

    /// The session in use. An idle session is no session: Codex then names a reset counted from
    /// now, which would log a new empty session on every pass.
    static func makeSession(cardID: String, snapshot: ProviderSnapshot, accountKey: String?) -> TeamQuotaReading? {
        let provider = ProviderAccountID.family(of: cardID)
        guard let label = sessionLabels[provider],
              let session = reading(label: label, kind: .session, provider: provider, cardID: cardID, snapshot: snapshot, accountKey: accountKey),
              session.percent > 0 else { return nil }
        return session
    }

    private static func reading(
        label: String, kind: Kind, provider: String, cardID: String, snapshot: ProviderSnapshot, accountKey: String?
    ) -> TeamQuotaReading? {
        for line in snapshot.lines {
            guard case .progress(let lineLabel, let used, let limit, _, let resetsAt?, let periodMs?, _) = line,
                  lineLabel == label, limit > 0, periodMs > 0 else { continue }
            return TeamQuotaReading(
                provider: provider,
                cardID: cardID,
                accountKey: accountKey,
                endsAt: resetsAt,
                periodHours: max(1, Int((Double(periodMs) / 3_600_000).rounded())),
                percent: max(0, used / limit * 100),
                observedAt: snapshot.refreshedAt,
                kind: kind
            )
        }
        return nil
    }
}

/// This Mac's record of its accounts' quota windows: for each one, the highest share seen used and
/// when it was last read. The share at the reset is what the plan's quota got used; the gap between
/// the last reading and the reset says how sure that is. A weekly (or shorter) limit window also keeps
/// the share seen at the end of each local day it was read, which gives the share used each day.
/// Limit windows are kept 40 days, like the upload window; sessions as long as a billing cycle.
struct TeamQuotaLog: Codable, Hashable, Sendable {
    struct Day: Codable, Hashable, Sendable {
        var day: String
        var percent: Double
    }

    struct Window: Codable, Hashable, Sendable {
        var provider: String
        var account: String
        var endsAt: Date
        var periodHours: Int
        var percent: Double
        var observedAt: Date
        var kind: TeamQuotaReading.Kind = .limit
        var days: [Day] = []
        /// Named by this Mac and its card (the login names no account), so the same account on
        /// another Mac goes up as another account.
        var perDevice = false

        init(
            provider: String, account: String, endsAt: Date, periodHours: Int, percent: Double, observedAt: Date,
            kind: TeamQuotaReading.Kind = .limit, days: [Day] = [], perDevice: Bool = false
        ) {
            self.provider = provider
            self.account = account
            self.endsAt = endsAt
            self.periodHours = periodHours
            self.percent = percent
            self.observedAt = observedAt
            self.kind = kind
            self.days = days
            self.perDevice = perDevice
        }

        /// Logs saved before sessions and daily readings have neither key.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            account = try container.decode(String.self, forKey: .account)
            endsAt = try container.decode(Date.self, forKey: .endsAt)
            periodHours = try container.decode(Int.self, forKey: .periodHours)
            percent = try container.decode(Double.self, forKey: .percent)
            observedAt = try container.decode(Date.self, forKey: .observedAt)
            kind = try container.decodeIfPresent(TeamQuotaReading.Kind.self, forKey: .kind) ?? .limit
            days = try container.decodeIfPresent([Day].self, forKey: .days) ?? []
            // Claude's and Codex's windows were all named per Mac before account ids.
            perDevice = try container.decodeIfPresent(Bool.self, forKey: .perDevice) ?? (provider != "cursor")
        }

        /// A day's share of the week only means something for a window of a week or less.
        var tracksDays: Bool { kind == .limit && periodHours <= 168 }

        /// Raises the share seen on the reading's day, keeping the latest `maxDays` days.
        mutating func recordDay(_ day: String, percent: Double) {
            guard tracksDays else { return }
            if let index = days.firstIndex(where: { $0.day == day }) {
                days[index].percent = max(days[index].percent, percent)
            } else {
                days.append(Day(day: day, percent: percent))
                days.sort { $0.day < $1.day }
                if days.count > TeamQuotaLog.maxDays { days.removeFirst(days.count - TeamQuotaLog.maxDays) }
            }
        }
    }

    var windows: [Window] = []

    static let retention: TimeInterval = 40 * 86_400
    /// Sessions only count in the plan's current cycle, and there are many of them.
    static let sessionRetention: TimeInterval = 32 * 86_400
    /// A week's window spans at most 8 calendar days; the server takes at most 10.
    static let maxDays = 8
    /// Readings of one window can name its reset a little differently (Codex counts it from now).
    static let sameWindowTolerance: TimeInterval = 3_600

    /// Folds readings in. A reading of a known window raises its share; a new window for an account
    /// whose window hasn't reset yet means it reset early (a claimed reset), so that one ends now.
    /// A reading names its account by `accountKey`; without one, by `perDeviceKey` (this Mac and its
    /// card). Once a card's account is known, its windows named per Mac move to the account's key, so
    /// the open week isn't sent twice. `dayKey` gives the local day of an instant.
    mutating func record(
        _ readings: [TeamQuotaReading],
        perDeviceKey: (TeamQuotaReading) -> String,
        now: Date,
        dayKey: (Date) -> String = { DailyUsageAccumulator.dayKey(from: $0) }
    ) {
        for reading in readings {
            let deviceKey = perDeviceKey(reading)
            let key = reading.accountKey ?? deviceKey
            if reading.accountKey != nil { adopt(deviceKey, as: key, provider: reading.provider, kind: reading.kind) }
            let endsAt = Self.roundedToHour(reading.endsAt)
            let day = dayKey(reading.observedAt)
            let mine = windows.indices.filter {
                windows[$0].provider == reading.provider && windows[$0].kind == reading.kind && windows[$0].account == key
            }
            if let index = mine.first(where: { abs(windows[$0].endsAt.timeIntervalSince(endsAt)) <= Self.sameWindowTolerance }) {
                windows[index].percent = max(windows[index].percent, reading.percent)
                windows[index].observedAt = max(windows[index].observedAt, reading.observedAt)
                windows[index].recordDay(day, percent: reading.percent)
                continue
            }
            for index in mine where windows[index].endsAt > reading.observedAt && windows[index].endsAt < endsAt {
                windows[index].endsAt = Self.roundedToHour(reading.observedAt)
            }
            var window = Window(
                provider: reading.provider, account: key, endsAt: endsAt,
                periodHours: reading.periodHours, percent: reading.percent, observedAt: reading.observedAt, kind: reading.kind,
                perDevice: reading.accountKey == nil
            )
            window.recordDay(day, percent: reading.percent)
            windows.append(window)
        }
        windows.removeAll { now.timeIntervalSince($0.endsAt) > ($0.kind == .session ? Self.sessionRetention : Self.retention) }
        windows.sort { ($0.provider, $0.kind.rawValue, $0.account, $0.endsAt) < ($1.provider, $1.kind.rawValue, $1.account, $1.endsAt) }
    }

    /// Renames a card's windows from its per-Mac key to its account's, merging into a window the
    /// account already has.
    private mutating func adopt(_ old: String, as new: String, provider: String, kind: TeamQuotaReading.Kind) {
        guard old != new else { return }
        for index in windows.indices.reversed() where windows[index].provider == provider && windows[index].kind == kind && windows[index].account == old {
            var window = windows.remove(at: index)
            window.account = new
            window.perDevice = false
            if let existing = windows.firstIndex(where: {
                $0.provider == provider && $0.kind == kind && $0.account == new
                    && abs($0.endsAt.timeIntervalSince(window.endsAt)) <= Self.sameWindowTolerance
            }) {
                windows[existing].percent = max(windows[existing].percent, window.percent)
                windows[existing].observedAt = max(windows[existing].observedAt, window.observedAt)
                for day in window.days { windows[existing].recordDay(day.day, percent: day.percent) }
            } else {
                windows.append(window)
            }
        }
    }

    /// The windows as the upload sends them. Readings go up to the hour, so an upload that only
    /// re-reads the same share stays equal to the last one and waits like any unchanged upload.
    var wire: [TeamUsageUpload.QuotaWindow] {
        var seen = Set<String>()
        return windows.compactMap { window in
            let endsAt = TeamUsageUpload.instant(window.endsAt)
            guard seen.insert("\(window.provider)|\(window.kind.rawValue)|\(window.account)|\(endsAt)").inserted else { return nil }
            return TeamUsageUpload.QuotaWindow(
                provider: window.provider,
                kind: window.kind.rawValue,
                account: window.account,
                endsAt: endsAt,
                periodHours: window.periodHours,
                percent: Self.tenth(window.percent),
                observedAt: TeamUsageUpload.instant(Self.flooredToHour(window.observedAt)),
                days: window.days.isEmpty ? nil : window.days.map { Day(day: $0.day, percent: Self.tenth($0.percent)) },
                perDevice: window.perDevice ? true : nil
            )
        }
    }

    static func tenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func roundedToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded() * 3_600)
    }

    static func flooredToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    }
}
