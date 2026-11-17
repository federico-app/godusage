import Foundation

/// A limit reset GodUsage claimed for one card (see `ClaudeResetClaimService`), kept so the Teams quota
/// log counts it exactly: Claude keeps a window's reset time when a reset is claimed, so the same week
/// gets another full limit (see `TeamQuotaLog.Claim`).
struct RecordedResetClaim: Codable, Hashable, Sendable {
    var cardID: String
    var at: Date
    /// The windows the claim refilled, as Anthropic names them (`five_hour`, `seven_day`, …).
    var cleared: [String]

    var windows: Set<ResetClaimWindow> { ResetClaimWindow.windows(cleared: cleared) }
}

/// A limit window a claimed reset can refill.
enum ResetClaimWindow: Hashable, Sendable {
    /// The 5-hour session (`five_hour`).
    case session
    /// The general weekly limit (`seven_day`; `seven_day_overage_included` is the same window with
    /// extra usage counted).
    case weekly
    /// One model's own weekly limit, like Fable's. A reset that clears only it leaves the general
    /// weekly limit as it was.
    case model(String)

    /// Reads Anthropic's names. Unknown names are logged and refill nothing GodUsage tracks: a name
    /// only counts for the general weekly limit when it is exactly that window, so a model-only reset
    /// can never add a limit to it.
    static func windows(cleared: [String]) -> Set<ResetClaimWindow> {
        var windows = Set<ResetClaimWindow>()
        for name in cleared.map({ $0.lowercased() }) {
            switch name {
            case "five_hour":
                windows.insert(.session)
            case "seven_day", "seven_day_overage_included":
                windows.insert(.weekly)
            default:
                if name.hasPrefix("seven_day_") {
                    windows.insert(.model(String(name.dropFirst("seven_day_".count))))
                } else if name.contains("fable") {
                    windows.insert(.model("fable"))
                } else {
                    AppLog.warn(.teams, "reset claim cleared an unknown window \(name); not counted")
                }
            }
        }
        return windows
    }
}

/// This Mac's recent claimed resets, saved so a claim still counts when the app quits before the upload
/// after it. Kept 8 days: a claim only changes the week it falls in.
enum ResetClaimLedger {
    static let key = "godusage.teams.resetClaims.v1"
    static let retention: TimeInterval = 8 * 86_400
    static let maxClaims = 50

    static func claims(defaults: UserDefaults, now: Date) -> [RecordedResetClaim] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([RecordedResetClaim].self, from: data).filter { now.timeIntervalSince($0.at) <= retention }
        } catch {
            AppLog.error(.teams, "couldn't read the saved reset claims, starting over: \(error)")
            return []
        }
    }

    static func record(_ claim: RecordedResetClaim, defaults: UserDefaults, now: Date) {
        var claims = claims(defaults: defaults, now: now)
        claims.append(claim)
        claims.sort { $0.at < $1.at }
        if claims.count > maxClaims { claims.removeFirst(claims.count - maxClaims) }
        do {
            defaults.set(try JSONEncoder().encode(claims), forKey: key)
            AppLog.info(.teams, "recorded a claimed reset for \(claim.cardID): \(claim.cleared.joined(separator: ", "))")
        } catch {
            AppLog.error(.teams, "couldn't save a claimed reset: \(error)")
        }
    }
}
