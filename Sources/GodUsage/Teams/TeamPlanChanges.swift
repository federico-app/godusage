import Foundation

/// A plan's name and monthly price.
struct TeamPlanTerms: Hashable, Sendable {
    var name: String
    var monthlyCostUSD: Double
}

/// Price-history edits on a plan, mirroring the server (`backend/src/planChanges.ts`): the plan's own
/// name and price are the terms in effect today, so editing them edits the current terms, and each
/// change carries the terms it replaces.
extension TeamPlan {
    /// The terms before the first change, and the changes with the current terms written into the one
    /// in effect today.
    func priceHistory(today: String) -> (base: TeamPlanTerms, changes: [Change]) {
        var changes = changes.sorted { $0.effectiveFrom < $1.effectiveFrom }
        let current = TeamPlanTerms(name: name, monthlyCostUSD: monthlyCostUSD)
        var base = changes.first.map { TeamPlanTerms(name: $0.previousName, monthlyCostUSD: $0.previousMonthlyCostUSD) } ?? current
        if let inEffect = changes.lastIndex(where: { $0.effectiveFrom <= today }) {
            changes[inEffect].name = current.name
            changes[inEffect].monthlyCostUSD = current.monthlyCostUSD
        } else {
            base = current
        }
        return (base, changes)
    }

    /// Marks a change from `effectiveFrom`, past or future. It replaces any change on or after that day.
    mutating func addChange(effectiveFrom: String, to terms: TeamPlanTerms, today: String) {
        let history = priceHistory(today: today)
        var kept = history.changes.filter { $0.effectiveFrom < effectiveFrom }
        kept.append(Change(effectiveFrom: effectiveFrom, name: terms.name, monthlyCostUSD: terms.monthlyCostUSD, previousName: "", previousMonthlyCostUSD: 0))
        setHistory(base: history.base, changes: kept, today: today)
    }

    /// Removes the change from `effectiveFrom`; the plan keeps the terms it had before it.
    mutating func cancelChange(effectiveFrom: String, today: String) {
        let history = priceHistory(today: today)
        setHistory(base: history.base, changes: history.changes.filter { $0.effectiveFrom != effectiveFrom }, today: today)
    }

    private mutating func setHistory(base: TeamPlanTerms, changes: [Change], today: String) {
        var previous = base
        self.changes = changes.map { change in
            var linked = change
            linked.previousName = previous.name
            linked.previousMonthlyCostUSD = previous.monthlyCostUSD
            previous = TeamPlanTerms(name: change.name, monthlyCostUSD: change.monthlyCostUSD)
            return linked
        }
        let current = self.changes.last { $0.effectiveFrom <= today }.map { TeamPlanTerms(name: $0.name, monthlyCostUSD: $0.monthlyCostUSD) } ?? base
        name = current.name
        monthlyCostUSD = current.monthlyCostUSD
    }

    /// The changes worth showing: in the current cycle or later.
    func visibleChanges(today: String) -> [Change] {
        let start = TeamPlanChanges.cycleStart(renewalDay: renewalDay, today: today)
        return changes.filter { $0.effectiveFrom >= start }
    }

    /// The earliest day a new change can take effect: after the change in effect today, if any.
    func earliestChangeDay(today: String) -> String? {
        changes.last { $0.effectiveFrom <= today }.map { TeamPlanChanges.addDays($0.effectiveFrom, 1) }
    }
}

/// Calendar-day arithmetic on `YYYY-MM-DD` keys, the change text, and the mismatch alert. Pure, so
/// it is unit-tested.
enum TeamPlanChanges {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func parts(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }

    private static func key(_ date: Date) -> String {
        let components = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The renewal in `month` (1-based, may overflow into other years): day 31 falls on the last day
    /// of shorter months.
    private static func renewal(year: Int, month: Int, day: Int) -> String {
        guard let first = utc.date(from: DateComponents(year: year, month: month, day: 1)),
              let length = utc.range(of: .day, in: .month, for: first)?.count,
              let date = utc.date(byAdding: .day, value: min(day, length) - 1, to: first)
        else { return "" }
        return key(date)
    }

    static func addDays(_ day: String, _ delta: Int) -> String {
        guard let (year, month, dayOfMonth) = parts(day),
              let date = utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
              let moved = utc.date(byAdding: .day, value: delta, to: date)
        else { return day }
        return key(moved)
    }

    /// The last renewal on or before `today`.
    static func cycleStart(renewalDay: Int, today: String) -> String {
        guard let (year, month, _) = parts(today) else { return today }
        let thisMonth = renewal(year: year, month: month, day: renewalDay)
        return thisMonth <= today ? thisMonth : renewal(year: year, month: month - 1, day: renewalDay)
    }

    /// The first renewal after `today`.
    static func nextRenewal(renewalDay: Int, today: String) -> String {
        guard let (year, month, _) = parts(cycleStart(renewalDay: renewalDay, today: today)) else { return today }
        return renewal(year: year, month: month + 1, day: renewalDay)
    }

    /// "↓ Downgrade to Claude Max 100 · $100/mo from Nov 30 (next renewal)" for a change still to
    /// come, "↓ Downgraded to Claude Max 100 · $100/mo on Oct 12" for one that applies already.
    static func describe(_ change: TeamPlan.Change, renewalDay: Int, today: String, dayLabel: (String) -> String = TeamsFormat.dayLabel) -> String {
        let past = change.effectiveFrom <= today
        let delta = change.monthlyCostUSD - change.previousMonthlyCostUSD
        let verb = delta < 0 ? (past ? "↓ Downgraded" : "↓ Downgrade")
            : delta > 0 ? (past ? "↑ Upgraded" : "↑ Upgrade")
            : (past ? "→ Changed" : "→ Change")
        let price = "\(monthly(change.monthlyCostUSD))/mo"
        let when = past
            ? "on \(dayLabel(change.effectiveFrom))"
            : "from \(dayLabel(change.effectiveFrom))" + (change.effectiveFrom == nextRenewal(renewalDay: renewalDay, today: today) ? " (next renewal)" : "")
        return "\(verb) to \(change.name) · \(price) \(when)"
    }

    /// The detected plans on the Macs of the members `memberIDs` covers (nil: everyone), deduplicated
    /// without case, sorted.
    static func detectedLabels(_ detections: [TeamDetectedPlan], provider: String, memberIDs: [String]?) -> [String] {
        var labels: [String] = []
        for detection in detections where detection.provider == provider && (memberIDs?.contains(detection.userID) ?? true) {
            if !labels.contains(where: { sameLabel($0, detection.plan) }) { labels.append(detection.plan) }
        }
        return labels.sorted()
    }

    /// The label to link a plan to without asking: the only one detected, when the plan has none.
    static func prefilledLink(_ plan: TeamPlan, labels: [String]) -> String? {
        plan.detectedPlan == nil && labels.count == 1 ? labels[0] : nil
    }

    static func sameLabel(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).lowercased() == rhs.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// One alert per team, provider, member, and detected plan. Plan ids change on every save, so
    /// they are not part of it.
    static func alertKey(teamID: String, provider: String, mismatch: TeamPlanMismatch) -> String {
        "\(teamID)|\(provider)|\(mismatch.userID)|\(mismatch.detectedPlan.lowercased())"
    }

    /// "Detected Max 5x on Bea's Mac. This plan says Max 20x ($200/mo)."
    static func mismatchMessage(_ mismatch: TeamPlanMismatch, plan: TeamPlanReport) -> String {
        "Detected \(mismatch.detectedPlan) on \(mismatch.displayName)’s Mac. \(plan.name) says \(plan.detectedPlan ?? plan.name) (\(monthly(plan.monthlyCostUSD))/mo)."
    }

    /// "$100", or "$19.99" when there are cents.
    static func monthly(_ amount: Double) -> String {
        Formatters.currency(amount, fractionDigits: amount.rounded() == amount ? 0 : 2)
    }
}
