import Foundation

@MainActor
final class CursorProvider: ProviderRuntime {
    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        icon: .providerMark("cursor"),
        links: [
            .init(label: "Status", url: "https://status.cursor.com/"),
            .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    /// Wall-clock budget for one refresh's spend-history fetch. Kept well under the 10s slow-refresh
    /// threshold: a steady-state refresh only re-fetches today and yesterday, and a first-time
    /// backfill that runs out of budget resumes on the next refresh.
    let spendHistoryBudget: TimeInterval
    let usageHistoryStore: CursorUsageHistoryStore

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = ModelPricingStore.livePricing,
        spendHistoryBudget: TimeInterval = 6,
        usageHistoryStore: CursorUsageHistoryStore = CursorUsageHistoryStore()
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
        self.spendHistoryBudget = spendHistoryBudget
        self.usageHistoryStore = usageHistoryStore
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                .exportingLimit("totalUsage", unit: "percent"),
            .percent(id: "cursor.auto", provider: provider, title: "Cursor Models", metricLabel: "Cursor models")
                .exportingLimit("autoUsage", unit: "percent"),
            .percent(id: "cursor.api", provider: provider, title: "Other Models", metricLabel: "Other models")
                .exportingLimit("apiUsage", unit: "percent"),
            .percent(id: "cursor.grokBot", provider: provider, title: "Grok Bot", metricLabel: "Grok Bot usage")
                .exportingLimit("grokBot", unit: "percent"),
            .boundedDollars(id: "cursor.onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100, valueWord: "spent")
                .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .boundedCount(id: "cursor.requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs)
                .exportingLimit("requests", unit: "requests"),
            .dollarBalance(id: "cursor.credits", provider: provider, title: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: true,
                    sourceNote: "From your Cursor usage history"
                )
        ] + WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: WidgetData.cursorUsageHistoryNote
        )
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: any auth state (state DB or keychain) counts. A protected
        // keychain item counts too — it is a real login even though only a manual refresh may ask
        // the user to approve reading it.
        await loadOffMainActor { [authStore] in authStore.loadCredentials() } != .none
    }

    func refresh() async -> ProviderSnapshot {
        // A manual refresh may raise the Keychain approval prompt (once, for GodUsage itself);
        // automatic refreshes stay prompt-free.
        let allowInteraction = ProviderRefreshContext.isManual
        let load = await loadOffMainActor { [authStore] in
            authStore.loadCredentials(allowKeychainInteraction: allowInteraction)
        }
        let state: CursorAuthState
        switch load {
        case .state(let loaded):
            state = loaded
        case .connectRequired:
            // The login exists but hasn't been loaded this process — the neutral Connect
            // affordance, not a warning.
            return ProviderSnapshot.connectPrompt(provider: provider, error: CursorAuthError.keychainConnectRequired)
        case .keychainPermissionRequired:
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.keychainPermissionRequired)
        case .unreadable:
            // Approval cannot fix a locked keychain or a failing securityd, so don't ask for it.
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.credentialStoreUnreadable)
        case .none:
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.notLoggedIn)
        }

        do {
            return try await probe(authState: state)
        } catch let error as CursorAuthError where error == .loginRenewalRequired {
            // The selected token lapsed or was rejected server-side. GodUsage never refreshes it, but
            // Cursor's app and its `agent` CLI keep separate copies — try a live one for the SAME
            // account once before telling the user to sign in again.
            // Logged here, before the outcome is known, so the log always records WHY a fallback
            // was attempted — every branch below reports a different result.
            AppLog.info(
                LogTag.auth("cursor"),
                "\(state.source) token was rejected; looking for this account's other local credential"
            )
            let alternativeLoad = await loadOffMainActor { [authStore] in
                authStore.sameAccountAlternative(to: state, allowKeychainInteraction: allowInteraction)
            }
            let alternative: CursorAuthState
            switch alternativeLoad {
            case .state(let candidate):
                alternative = candidate
            case .connectRequired:
                // The live credential may be the one GodUsage hasn't loaded yet — offer the connect
                // prompt instead of sending the user to sign in again.
                return ProviderSnapshot.connectPrompt(
                    provider: provider,
                    error: CursorAuthError.keychainConnectRequired
                )
            case .keychainPermissionRequired:
                // The live credential may be the one GodUsage can't read yet — say so instead of
                // sending the user to sign in again.
                return ProviderSnapshot.error(
                    provider: provider,
                    error: CursorAuthError.keychainPermissionRequired
                )
            case .unreadable:
                return ProviderSnapshot.error(
                    provider: provider,
                    error: CursorAuthError.credentialStoreUnreadable
                )
            case .none:
                AppLog.info(
                    LogTag.auth("cursor"),
                    "\(state.source) token rejected and this account has no other local credential; renewal required"
                )
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            AppLog.info(LogTag.auth("cursor"), "retrying with this account's \(alternative.source) credential")
            do {
                return try await probe(authState: alternative)
            } catch let alternativeError as CursorAuthError where alternativeError == .loginRenewalRequired {
                // Both credentials for this account are dead: renewal really is the answer.
                AppLog.info(
                    LogTag.auth("cursor"),
                    "both local Cursor credentials for this account were rejected; renewal required"
                )
                return ProviderSnapshot.error(provider: provider, error: alternativeError)
            } catch {
                // The alternative may be perfectly valid and the problem is connectivity or Cursor
                // itself. Reporting the original renewal notice here would tell the user to sign in
                // again over a network blip, so surface what actually failed.
                AppLog.error(
                    LogTag.auth("cursor"),
                    "this account's other local credential also failed: \(error.localizedDescription)"
                )
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Read-only: GodUsage never calls Cursor's token endpoint and never writes its state database or
    /// keychain items — the Cursor app owns its login and its rotation. A lapsed token is reported
    /// for renewal, not renewed.
    private func probe(authState: CursorAuthState) async throws -> ProviderSnapshot {
        let accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }
        // An expired stamp means the calls below are doomed; skip the network round trips. GodUsage
        // never refreshes a Cursor token — the Cursor app owns rotation — so renewal is Cursor's.
        if authStore.isExpired(accessToken) {
            AppLog.info(LogTag.auth("cursor"), "access token expired; renewal belongs to Cursor")
            throw CursorAuthError.loginRenewalRequired
        }

        let usageResponse: HTTPResponse
        do {
            usageResponse = try await usageClient.fetchUsage(accessToken: accessToken)
        } catch {
            throw CursorUsageError.connectionFailed
        }
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.loginRenewalRequired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        let currentToken = accessToken

        // Some Enterprise / Team seats still get GetPlanInfo = Pro. The org membership may steer the
        // fallback route and the badge, but `mapUsage` keeps branching on GetPlanInfo alone.
        let (planInfoName, planInfoUnavailable) = await fetchPlanName(accessToken: currentToken)
        let membershipType = authState.membershipType
        let routingPlanName = CursorUsageMapper.routingPlanName(planInfoName: planInfoName, membershipType: membershipType)
        let displayPlanName = CursorUsageMapper.resolvedPlanName(planInfoName: planInfoName, membershipType: membershipType)
            ?? routingPlanName
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: routingPlanName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.shouldFallback {
            var mapped = try await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: displayPlanName,
                unavailableMessage: fallback.message
            )
            await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
            let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
            return snapshot(mapped, usageHistory: history)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            do {
                var mapped = try await requestBasedResult(
                    accessToken: currentToken,
                    planName: displayPlanName,
                    unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
                )
                await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
                return snapshot(mapped)
            } catch {
                AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage fallback failed")
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: currentToken)
        let stripeBalanceCents = await fetchStripeBalanceCents(accessToken: currentToken)
        var mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planInfoName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(planInfoName: planInfoName, membershipType: membershipType)
        await enrichFromUsageSummaryIfNeeded(
            &mapped,
            usage: usage,
            planInfoName: planInfoName,
            membershipType: membershipType,
            accessToken: currentToken
        )
        await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
        let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
        return snapshot(mapped, usageHistory: history)
    }

    /// Org seats (local org membership or a team-shaped payload) can map fine from the primary call
    /// but omit on-demand there, and GetPlanInfo may still say Pro. usage-summary carries both the
    /// Extra Usage bucket and the live membership. Personal seats are never probed.
    private func enrichFromUsageSummaryIfNeeded(
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

    /// Grok Bot uses the same Cursor account but keeps a separate weekly allowance. Missing access is
    /// normal for ineligible accounts; malformed data and request failures remain visible in diagnostics.
    private func appendGrokBotUsage(to lines: inout [MetricLine], accessToken: String) async {
        guard let usage = await fetchOptionalJSONObject(label: "Grok Bot usage", request: {
            try await self.usageClient.fetchGrokBotUsage(accessToken: accessToken)
        }) else {
            return
        }
        guard usage["usesPooledEnterpriseAllowance"] as? Bool != true,
              usage["hasNonZeroIncludedLimit"] as? Bool != false,
              usage["includedLimitZero"] as? Bool != true
        else {
            return
        }
        guard let line = CursorUsageMapper.mapGrokBotUsage(usage) else {
            if usage["usagePercent"] != nil || usage["hasNonZeroIncludedLimit"] as? Bool == true ||
                usage["hasAvailableUsage"] as? Bool == true {
                AppLog.warn(LogTag.plugin("cursor"), "optional Grok Bot usage response contained invalid usage metadata")
            }
            return
        }
        lines.append(line)
    }

    /// Strictly additive: build the 30-day spend history from Cursor's usage events and append the
    /// per-day spend tiles. Any failure, or a backfill that hasn't stored all 30 days yet, appends
    /// nothing, so the live Cursor mapping is never affected and the dashboard keeps its last-good
    /// history.
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async -> ProviderUsageHistory? {
        guard let session = CursorUsageClient.session(from: accessToken) else {
            AppLog.warn(LogTag.plugin("cursor"), "usage events could not be prepared from the current session")
            return nil
        }
        let currentTime = now()
        let fetcher = CursorSpendHistoryFetcher(
            client: usageClient,
            store: usageHistoryStore,
            budget: spendHistoryBudget
        )
        guard let days = await fetcher.refresh(
            accessToken: accessToken,
            userID: session.userID,
            now: currentTime
        ) else {
            return nil
        }
        let pricing = await pricing()
        let rows = days.flatMap { dayStart, day in
            day.models.map { model, tokens in
                CursorUsageRow(
                    date: dayStart,
                    model: model,
                    tokens: tokens,
                    // Day totals combine many requests, so their size can't prove any one request
                    // crossed a long-context threshold; bill at the base rate.
                    imputedCostDollars: pricing.estimatedCostDollars(
                        model: model,
                        tokens: tokens,
                        applyLongContextRates: false
                    )
                )
            }
        }
        var history = CursorUsageMapper.appendSpendLines(rows: rows, now: currentTime, pricing: pricing, to: &lines)
        history.accountKey = TeamAccountKey.make(provider: "cursor", accountID: session.userID)
        return history
    }

    private func fetchPlanName(accessToken: String) async -> (String?, Bool) {
        guard let body = await fetchOptionalJSONObject(label: "plan", request: {
            try await self.usageClient.fetchPlan(accessToken: accessToken)
        }) else {
            return (nil, true)
        }
        guard let planInfo = body["planInfo"] as? [String: Any],
              let planName = (planInfo["planName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            AppLog.warn(LogTag.plugin("cursor"), "optional plan response contained invalid plan metadata")
            return (nil, true)
        }
        return (planName, false)
    }

    private func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let body = await fetchOptionalJSONObject(label: "credit-grants", request: {
            try await self.usageClient.fetchCredits(accessToken: accessToken)
        }) else {
            return nil
        }
        // Connect serializes proto3 JSON, which omits default values: an account with no grants
        // answers `{}` (no `hasCreditGrants: false`), and a grant nothing has been spent from omits
        // `usedCents`. Absent fields are those defaults; present ones must still be well-formed.
        let rawHasCreditGrants = body["hasCreditGrants"] ?? false
        guard let hasCreditGrants = rawHasCreditGrants as? Bool,
              CFGetTypeID(rawHasCreditGrants as CFTypeRef) == CFBooleanGetTypeID() else {
            AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
            return nil
        }
        if hasCreditGrants {
            guard let totalCents = ProviderParse.number(body["totalCents"]), totalCents > 0,
                  let usedCents = body["usedCents"] == nil ? 0 : ProviderParse.number(body["usedCents"]),
                  usedCents >= 0 else {
                AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
                return nil
            }
        }
        return body
    }

    private func fetchStripeBalanceCents(accessToken: String) async -> Double {
        guard let body = await fetchOptionalJSONObject(label: "prepaid-balance", request: {
            try await self.usageClient.fetchStripeBalance(accessToken: accessToken)
        }) else {
            return 0
        }
        guard ProviderParse.number(body["customerBalance"]) != nil else {
            AppLog.warn(LogTag.plugin("cursor"), "optional prepaid-balance response contained invalid balance metadata")
            return 0
        }
        return CursorUsageMapper.stripeBalanceCents(from: body)
    }

    /// Optional endpoints enrich a usable primary snapshot; they never fail the whole provider. Keep
    /// their boundary handling in one place so transport, preparation, status, and schema failures are
    /// all visible with fixed, credential-free diagnostics.
    private func fetchOptionalJSONObject(
        label: String,
        request: () async throws -> HTTPResponse?
    ) async -> [String: Any]? {
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request failed")
            return nil
        }
        guard let response else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request could not be prepared from the current session")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) response was invalid")
            return nil
        }
        return body
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func usageSummaryAndRequestResult(
        accessToken: String,
        planName: String?,
        unavailableMessage: String
    ) async throws -> CursorMappedUsage {
        let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        })
        if let summary, !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
        }
        let requestUsage = await fetchOptionalJSONObject(label: "request-based usage", request: {
            try await self.usageClient.fetchRequestBasedUsage(accessToken: accessToken)
        })
        if let requestUsage, !CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage response contained no usable usage fields")
        }
        return try CursorUsageSummaryMapper.map(
            summary: summary,
            requestUsage: requestUsage,
            planName: planName,
            unavailableMessage: unavailableMessage
        )
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback
    }

    private func snapshot(_ mapped: CursorMappedUsage, usageHistory: ProviderUsageHistory? = nil) -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }
}
