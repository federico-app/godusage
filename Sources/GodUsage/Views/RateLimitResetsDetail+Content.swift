import SwiftUI

/// The resets popover's pure, unit-testable pieces: what the body renders, the timeline entries, the
/// result banners, and which claim outcomes keep the idempotency key.
extension RateLimitResetsDetail {
    /// `.failed` and `.unconfirmed` may hide a claim that went through, so a retry must reuse its key.
    static func keepsRequestID(_ outcome: ResetClaimOutcome) -> Bool {
        switch outcome {
        case .failed, .unconfirmed: true
        case .success, .nothingToReset, .noCredit, .unavailableNow: false
        }
    }

    /// The result line for each outcome. Static so the copy is unit-testable without a view.
    static func banner(for outcome: ResetClaimOutcome, now: Date = Date()) -> Banner {
        switch outcome {
        case .success:
            return .init(text: "Reset claimed. Enjoy!", icon: "checkmark.circle.fill", tint: .green)
        case .nothingToReset:
            return .init(text: "Your usage doesn't need a reset yet", icon: "info.circle.fill", tint: .accentColor)
        case .noCredit:
            return .init(text: "That reset is no longer available", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .unconfirmed:
            return .init(text: "Your reset may still be going through. Check again in a minute.", icon: "clock.fill", tint: .accentColor)
        case .unavailableNow(let until):
            let wait = until.flatMap { Formatters.whenLabel(at: $0, mode: .relative, now: now) }
                .map { $0 == Formatters.imminent ? " Try again soon." : " Try again in \($0)." } ?? ""
            return .init(text: "Resets can't be used right now.\(wait)", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            return .init(text: "Couldn't reset usage. Please try again.", icon: "xmark.circle.fill", tint: .red)
        }
    }

    /// The tint + glyph for a result banner.
    struct Banner: Equatable {
        let text: String
        let icon: String
        let tint: Color
    }

    /// What the body renders, resolved once from the count and expiry list so the "empty vs. count-only
    /// vs. timeline" choice is unit-testable and can't drift between the view and its tests.
    enum Content: Equatable {
        case timeline([Entry])
        case unknownExpiries(count: Int)
        case empty
    }

    /// Empty `expiries` is ambiguous: a genuinely empty balance (`count == 0`) shows the empty state,
    /// but a positive `count` with no expiries means the dedicated expiry fetch was unavailable and the
    /// row fell back to the usage-body count — show that count rather than "no resets".
    static func content(count: Int, expiries: [Date], now: Date = Date()) -> Content {
        let entries = entries(from: expiries, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count > 0 { return .unknownExpiries(count: count) }
        return .empty
    }

    /// One timeline node's display strings, derived from a credit's expiry instant. Pure and static so
    /// the phrasing is unit-testable without a view.
    struct Entry: Identifiable, Equatable {
        let id: Int          // 0-based row index (soonest first)
        let number: Int      // 1-based reset number, shown inside the dot
        let date: Date       // the credit's expiry instant — identity for the claim flow
        let key: Key         // view identity: the expiry plus its ordinal among equal expiries
        let severity: WidgetData.MeterSeverity
        let time: String       // exact expiry, e.g. "Jul 12 at 5:30 PM"; "Expiring soon" when imminent
        let countdown: String? // "12d 18h"; nil when imminent (no useful countdown to show)

        struct Key: Hashable {
            let date: Date
            let ordinal: Int
        }

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    /// Build the timeline entries from raw expiry instants: sort soonest-first, number from 1, and pair
    /// each exact expiry time with its countdown. A past-due or ≤5-minute expiry can't print a useful
    /// exact time or countdown, so it reads "Expiring soon" with no trailing countdown. Imminence keys
    /// off the *relative* window — `Formatters.whenLabel(.relative)` collapses to `soon` at ≤5 minutes,
    /// while `.absolute` only collapses once past-due — so both formats agree instead of the exact time
    /// printing a wall-clock while the countdown reads "soon".
    static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        var seen: [Date: Int] = [:]
        return expiries.sorted().enumerated().map { index, date in
            let ordinal = seen[date, default: 0]
            seen[date] = ordinal + 1
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                date: date,
                key: Entry.Key(date: date, ordinal: ordinal),
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}
