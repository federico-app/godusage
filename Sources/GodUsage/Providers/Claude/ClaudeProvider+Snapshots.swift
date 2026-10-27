import Foundation

/// Snapshot assembly: the always-local spend tiles and trend merged with whatever live usage is
/// available, plus the degraded snapshots for unauthenticated installs and lapsed logins.
extension ClaudeProvider {
    /// API-key-only (or otherwise unauthenticated) installs still have local session logs. Serve those
    /// spend tiles under the existing Not logged in notice when they contain usage; otherwise keep the
    /// hard error card so an empty machine does not grow a blank Claude card.
    func unauthenticatedLocalUsageSnapshot() async -> ProviderSnapshot {
        let error = ClaudeAuthError.notLoggedIn
        let snapshot = await localUsageSnapshot(
            mapped: ClaudeMappedUsage(plan: nil, lines: []),
            warning: error.localizedDescription,
            loginRequired: true
        )
        let hasLocalUsage = snapshot.usageHistory?.series.daily.contains {
            $0.totalTokens > 0 || ($0.costUSD ?? 0) > 0
        } == true
        guard hasLocalUsage else {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        return snapshot
    }

    /// Terminal failure handling: a lapsed login (`isLoginRenewal`) degrades to the local spend tiles
    /// under a renewal notice — the data is still trustworthy and the fix belongs to the owning Claude
    /// app — while every other failure stays a hard error card. `renewalState` only feeds the plan
    /// badge; a stale Desktop-only login has none and still degrades.
    func failureSnapshot(
        _ error: ClaudeAuthError,
        renewalState: ClaudeCredentialState?
    ) async -> ProviderSnapshot {
        guard error.isLoginRenewal else {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        AppLog.info(LogTag.auth("claude"), "login needs renewal; serving local usage with a renewal notice")
        let mapped = ClaudeMappedUsage(
            plan: renewalState.flatMap {
                ClaudeUsageMapper.formatPlan(
                    subscriptionType: $0.displayOAuth.subscriptionType,
                    rateLimitTier: $0.displayOAuth.rateLimitTier
                )
            },
            lines: []
        )
        return await localUsageSnapshot(mapped: mapped, warning: error.localizedDescription, loginRequired: true)
    }

    /// Assembles the published snapshot from whatever live usage is available plus the always-local
    /// spend tiles and trend.
    func localUsageSnapshot(
        mapped initialMapped: ClaudeMappedUsage,
        warning: String?,
        warningAction: ProviderSnapshot.WarningAction = .refresh,
        warningIsConnectPrompt: Bool = false,
        loginRequired: Bool? = nil
    ) async -> ProviderSnapshot {
        var mapped = initialMapped
        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store, merged with Claude usage that happened inside pi (attributed back here).
        // Both scans run on their scanner actors, off the main actor.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning,
            warningAction: warningAction,
            warningIsConnectPrompt: warningIsConnectPrompt,
            loginRequired: loginRequired
        )
    }
}
