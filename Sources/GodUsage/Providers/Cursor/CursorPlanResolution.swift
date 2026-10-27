import Foundation

/// Plan-name resolution for the Cursor badge and the fallback routing. Some Enterprise / Team seats
/// still get `GetPlanInfo.planName = Pro`, so the billing membership (Cursor's local
/// `stripeMembershipType`, or `usage-summary`'s `membershipType`) can correct the badge. Routing and
/// display are kept apart: personal memberships never fill an empty GetPlanInfo for routing, and
/// `mapUsage` keeps branching on GetPlanInfo alone.
extension CursorUsageMapper {
    /// Membership values that identify an org-billed Cursor seat.
    static let orgMembershipTypes: Set<String> = ["enterprise", "team"]

    /// Plan name for the request / Enterprise fallback routing. An org membership may promote the
    /// route; a personal one must not fill an empty GetPlanInfo and disable the unknown-plan fallback.
    static func routingPlanName(planInfoName: String?, membershipType: String?) -> String? {
        if let membership = normalizedMembership(membershipType), orgMembershipTypes.contains(membership) {
            return membership
        }
        return planInfoName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Badge plan. An org membership wins only when GetPlanInfo is missing or still says Pro, so an
    /// explicit non-Pro plan name (Ultra, Business, …) is kept.
    static func resolvedPlanName(planInfoName: String?, membershipType: String?) -> String? {
        let membership = normalizedMembership(membershipType)
        let planInfo = planInfoName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let membership, orgMembershipTypes.contains(membership),
           planInfo == nil || ["pro", "pro plan"].contains(planInfo?.lowercased() ?? "") {
            return membership
        }
        return planInfo ?? membership
    }

    static func resolvedPlanLabel(planInfoName: String?, membershipType: String?) -> String? {
        planLabel(resolvedPlanName(planInfoName: planInfoName, membershipType: membershipType))
    }

    /// A local org membership wins; otherwise a live org membership from usage-summary beats a stale
    /// local personal one.
    static func preferredMembership(local: String?, summary: String?) -> String? {
        let localMembership = normalizedMembership(local)
        let summaryMembership = normalizedMembership(summary)
        if let localMembership, orgMembershipTypes.contains(localMembership) {
            return localMembership
        }
        if let summaryMembership, orgMembershipTypes.contains(summaryMembership) {
            return summaryMembership
        }
        return localMembership ?? summaryMembership
    }

    static func normalizedMembership(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }
}
