import Foundation

/// One reading of an account's limiting quota window, from a card's latest snapshot: Claude's and
/// Codex's weekly window, Cursor's billing cycle. The Plans report compares what a plan's accounts
/// use of it with what the plan costs.
struct TeamQuotaReading: Hashable, Sendable {
    var provider: String
    var cardID: String
    /// A fingerprint that names the account the same on every Mac (Cursor's), when there is one.
    var accountKey: String?
    var endsAt: Date
    var periodHours: Int
    /// Share of the window used, 0–100 (more when over the limit).
    var percent: Double
    var observedAt: Date

    /// The quota row each provider's plan is limited by. Other providers send none.
    static let limitingLabels = ["claude": "Weekly", "codex": "Weekly", "cursor": "Total usage"]

    static func make(cardID: String, snapshot: ProviderSnapshot, accountKey: String?) -> TeamQuotaReading? {
        let provider = ProviderAccountID.family(of: cardID)
        guard let label = limitingLabels[provider] else { return nil }
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
                observedAt: snapshot.refreshedAt
            )
        }
        return nil
    }
}

/// This Mac's record of its accounts' quota windows: for each one, the highest share seen used and
/// when it was last read. The share at the reset is what the plan's quota got used; the gap between
/// the last reading and the reset says how sure that is. Kept 40 days, like the upload window.
struct TeamQuotaLog: Codable, Hashable, Sendable {
    struct Window: Codable, Hashable, Sendable {
        var provider: String
        var account: String
        var endsAt: Date
        var periodHours: Int
        var percent: Double
        var observedAt: Date
    }

    var windows: [Window] = []

    static let retention: TimeInterval = 40 * 86_400
    /// Readings of one window can name its reset a little differently (Codex counts it from now).
    static let sameWindowTolerance: TimeInterval = 3_600

    /// Folds readings in. A reading of a known window raises its share; a new window for an account
    /// whose window hasn't reset yet means it reset early (a claimed reset), so that one ends now.
    /// `account` gives the account's fingerprint for a reading.
    mutating func record(_ readings: [TeamQuotaReading], account: (TeamQuotaReading) -> String, now: Date) {
        for reading in readings {
            let key = account(reading)
            let endsAt = Self.roundedToHour(reading.endsAt)
            let mine = windows.indices.filter { windows[$0].provider == reading.provider && windows[$0].account == key }
            if let index = mine.first(where: { abs(windows[$0].endsAt.timeIntervalSince(endsAt)) <= Self.sameWindowTolerance }) {
                windows[index].percent = max(windows[index].percent, reading.percent)
                windows[index].observedAt = max(windows[index].observedAt, reading.observedAt)
                continue
            }
            for index in mine where windows[index].endsAt > reading.observedAt && windows[index].endsAt < endsAt {
                windows[index].endsAt = Self.roundedToHour(reading.observedAt)
            }
            windows.append(Window(
                provider: reading.provider, account: key, endsAt: endsAt,
                periodHours: reading.periodHours, percent: reading.percent, observedAt: reading.observedAt
            ))
        }
        windows.removeAll { now.timeIntervalSince($0.endsAt) > Self.retention }
        windows.sort { ($0.provider, $0.account, $0.endsAt) < ($1.provider, $1.account, $1.endsAt) }
    }

    /// The windows as the upload sends them. Readings go up to the hour, so an upload that only
    /// re-reads the same share stays equal to the last one and waits like any unchanged upload.
    var wire: [TeamUsageUpload.QuotaWindow] {
        var seen = Set<String>()
        return windows.compactMap { window in
            let endsAt = TeamUsageUpload.instant(window.endsAt)
            guard seen.insert("\(window.provider)|\(window.account)|\(endsAt)").inserted else { return nil }
            return TeamUsageUpload.QuotaWindow(
                provider: window.provider,
                account: window.account,
                endsAt: endsAt,
                periodHours: window.periodHours,
                percent: (window.percent * 10).rounded() / 10,
                observedAt: TeamUsageUpload.instant(Self.flooredToHour(window.observedAt))
            )
        }
    }

    static func roundedToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded() * 3_600)
    }

    static func flooredToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    }
}
