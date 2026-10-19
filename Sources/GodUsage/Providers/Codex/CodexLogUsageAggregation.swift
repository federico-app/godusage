import Foundation

extension CodexLogUsageScanner {
    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    private struct PricingContextKey: Hashable {
        var model: String
        /// `CodexUsagePricing.pricingModel(for:at:)`, so auto-review's paid eras and its free era
        /// never reuse each other's rates.
        var pricingModel: String
        var isFast: Bool
    }

    private enum PricingResolution {
        case priced(model: String, context: EventPricingContext)
        case unpriced(model: String?)
    }

    private struct EventPricingContext {
        var rates: ModelRates
        var rateModel: String
        var fastTier: Bool

        func cost(for event: Event) -> Double {
            CodexLogUsageScanner.cost(
                rates: rates, event: event, model: rateModel, fastTier: fastTier
            )
        }
    }

    /// Bucket events into local calendar days. Identical events across files (copied session logs)
    /// count once. Cost is per-event Codex math (see type doc).
    ///
    /// Events that can't be priced (an unknown model, or a blank slug) are excluded from every displayed
    /// total — tokens, dollars, the trend, and the model breakdown — because mixing measured tokens with
    /// unpriceable ones makes the figures incoherent. An unknown model's name lands in
    /// `unknownModelsByDay` (the tile's warning triangle), the only place unpriceable usage surfaces.
    /// A blank slug is unattributed, not unknown — there is no name to warn about.
    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing
    ) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()
        var pricingContexts: [PricingContextKey: PricingResolution] = [:]
        var dayKeys = DailyUsageAccumulator.DayKeyCache()

        for event in events where event.timestamp >= since {
            let key = EventKey(
                timestamp: event.timestamp, model: event.model,
                input: event.input, cached: event.cached, output: event.output,
                reasoning: event.reasoning, total: event.total
            )
            guard seen.insert(key).inserted else { continue }

            let day = dayKeys.key(for: event.timestamp)
            let contextKey = PricingContextKey(
                model: event.model,
                pricingModel: CodexUsagePricing.pricingModel(for: event.model, at: event.timestamp),
                isFast: event.isFast
            )
            let resolution: PricingResolution
            if let cached = pricingContexts[contextKey] {
                resolution = cached
            } else {
                resolution = resolvePricingContext(
                    rawModel: event.model,
                    timestamp: event.timestamp,
                    isFast: event.isFast,
                    pricing: pricing
                )
                pricingContexts[contextKey] = resolution
            }

            switch resolution {
            case .priced(let model, let context):
                accumulator.add(
                    day: day,
                    tokens: event.total,
                    cost: context.cost(for: event),
                    model: model
                )
            case .unpriced(let model):
                if event.total > 0, let model {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }

        return accumulator.build()
    }

    private static func resolvePricingContext(
        rawModel: String,
        timestamp: Date,
        isFast: Bool,
        pricing: ModelPricing
    ) -> PricingResolution {
        // The breakdown, unknown-model warning, and hover panel share the measured slug. Rates
        // may come from a dated fallback (auto-review before it went free) that must not replace
        // that identity.
        guard let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .unpriced(model: nil)
        }
        let resolution = CodexUsagePricing.resolveRates(pricing: pricing, model: model, at: timestamp)
        guard let rates = resolution.rates else {
            return .unpriced(model: model)
        }
        // Codex speed is a provider tier, not Cursor's `-fast` price variant. A fast alias applies
        // the Codex multiplier exactly once through the unscaled base rates. Native events without
        // a `-fast` slug still honor the session's recorded priority flag.
        let appliesCodexFastTier = resolution.isFastAlias ? resolution.hasBaseRates : isFast
        return .priced(
            model: model,
            context: EventPricingContext(
                rates: rates,
                rateModel: resolution.rateModel,
                fastTier: appliesCodexFastTier
            )
        )
    }

    /// Native rollout events count cached tokens inside `input`; the shared estimator takes disjoint
    /// buckets, so the cached portion is subtracted here rather than in `CodexUsagePricing`.
    static func cost(rates: ModelRates, event: Event, model: String, fastTier: Bool) -> Double {
        CodexUsagePricing.cost(
            rates: rates,
            tokens: TokenBreakdown(
                input: max(0, event.input - event.cached),
                cacheRead: event.cached,
                output: event.output
            ),
            model: model,
            fastTier: fastTier
        )
    }
}
