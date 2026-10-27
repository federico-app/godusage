import Foundation

extension CursorProvider {
    /// Org seats (local org membership or a team-shaped payload) can map fine from the primary call
    /// but omit on-demand there, and GetPlanInfo may still say Pro. usage-summary carries both the
    /// Extra Usage bucket and the live membership. Personal seats are never probed.
    func enrichFromUsageSummaryIfNeeded(
        _ mapped: inout CursorMappedUsage,
        usage: [String: Any],
        planInfoName: String?,
        membershipType: String?,
        accessToken: String
    ) async {
        let needsOnDemand = !mapped.lines.contains { $0.label == "On-demand" }
        let localIsOrg = CursorUsageMapper.normalizedMembership(membershipType)
            .map(CursorUsageMapper.orgMembershipTypes.contains) ?? false
        guard localIsOrg || CursorPlanUsageFacts(usage: usage).isTeamByShape else { return }
        // A local org membership already fixed the badge; nothing left to learn when on-demand is present.
        if localIsOrg, !needsOnDemand { return }

        guard let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        }) else {
            return
        }
        guard CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
            return
        }
        CursorUsageSummaryMapper.appendMissingOnDemand(from: summary, to: &mapped.lines)
        let membership = CursorUsageMapper.preferredMembership(
            local: membershipType,
            summary: summary["membershipType"] as? String
        )
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(planInfoName: planInfoName, membershipType: membership)
            ?? mapped.plan
    }
}
