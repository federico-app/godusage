import Foundation

/// Rebuilds a snapshot's history rows (Today, Yesterday, Last 30 Days, Usage Trend) from its
/// normalized daily history.
enum UsageHistorySnapshotRenderer {
    private static let historyLabels: Set<String> = ["Today", "Yesterday", "Last 30 Days", "Usage Trend"]

    static func render(
        local snapshot: ProviderSnapshot,
        history: ProviderUsageHistory,
        descriptor: UsageHistoryDescriptor,
        now: Date = Date()
    ) -> ProviderSnapshot {
        var result = snapshot
        result.lines.removeAll { historyLabels.contains($0.label) }
        SpendTileMapper.appendTokenUsage(
            history.series,
            to: &result.lines,
            now: now,
            estimated: descriptor.estimatedCost,
            unknownModelsByDay: history.unknownModelsByDay,
            modelUsage: history.modelUsage,
            modelSourceNote: descriptor.sourceNote
        )
        SpendTileMapper.appendUsageTrend(
            history.series,
            to: &result.lines,
            now: now,
            note: descriptor.sourceNote
        )
        return result
    }
}
