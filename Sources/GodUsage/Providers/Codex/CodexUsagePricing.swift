import Foundation

/// Codex-specific request pricing shared by native rollout logs and supplementary agents. The public
/// pricing catalogs provide base model rates, but Codex also has provider-specific long-context,
/// prompt-cache, and priority-tier rules that must be applied consistently regardless of which local
/// tool produced the request.
enum CodexUsagePricing {
    static let autoReviewModel = "codex-auto-review"
    /// Auto-review is free for ChatGPT sign-ins from October 6, 2026. The announcement gives a calendar
    /// date, not an activation time, so the cutoff is that day's start in UTC. Earlier requests keep
    /// their dated estimates: https://x.com/thsottiaux/status/2107368734981517634.
    static let autoReviewFreeSince = GodUsageISO8601.date(from: "2026-10-06T00:00:00Z")!

    /// `codex-auto-review` release timeline (newest first), from ccusage's embedded snapshot: a
    /// request on/after a release (00:00 UTC) prices as that codex model, until auto-review went free.
    ///
    /// The `gpt-5.6-luna` entry is ours; ccusage's snapshot still stops at gpt-5.5. OpenAI moved
    /// auto-review onto the GPT-5.6 family when it shipped on 2026-07-09, and the Codex model
    /// catalog (`~/.codex/models_cache.json`) lists `codex-auto-review` with Luna's exact profile.
    private static let autoReviewFallbacks: [(releasedOn: Date, model: String)] = [
        ("2026-07-09", "gpt-5.6-luna"),
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ].map { (GodUsageISO8601.date(from: $0.0 + "T00:00:00Z")!, $0.1) }

    static func isFreeAutoReview(model: String, at timestamp: Date) -> Bool {
        model == autoReviewModel && timestamp >= autoReviewFreeSince
    }

    /// The model whose rates price a request. Only auto-review changes over time: its dated paid
    /// model before the free cutoff, its own slug (priced at $0) from then on. Doubles as a
    /// prepared-rates cache key so historical and free auto-review never share rates.
    static func pricingModel(for model: String, at timestamp: Date) -> String {
        guard model == autoReviewModel, timestamp < autoReviewFreeSince else { return model }
        return autoReviewFallbacks.first(where: { timestamp >= $0.releasedOn })?.model ?? "gpt-5"
    }

    /// Everything Codex pricing derives from one effective model, resolved once so a scanner pricing
    /// thousands of requests does not re-walk the supplement's alias rules per row.
    struct Prepared: Sendable {
        /// Base rates with Codex's long-context, cache, and priority adjustments already applied.
        var rates: ModelRates
        var fastTier: Bool
    }

    /// The catalog lookup Codex layers its rules on. `rates` is nil when the model cannot be priced;
    /// the other fields stay meaningful so callers can still inspect the resolved slug.
    struct RateResolution {
        var rates: ModelRates?
        /// The unscaled base model whose name selects Codex's long-context and priority rules.
        var rateModel: String
        var isFastAlias: Bool
        /// The unscaled base entry existed, so the Codex multiplier can be applied to it exactly once.
        var hasBaseRates: Bool
    }

    /// Codex speed is a provider tier, not Cursor's `-fast` price variant. Resolve a fast alias through
    /// its unscaled base rates so the Codex multiplier applies once; if a fast-only model has no base
    /// entry, its already-scaled rate is retained and no second multiplier is applied.
    static func resolveRates(pricing: ModelPricing, model: String, at timestamp: Date) -> RateResolution {
        // Free requests keep their measured tokens and model name, without a catalog lookup.
        if isFreeAutoReview(model: model, at: timestamp) {
            return RateResolution(
                rates: ModelRates(inputPerMillion: 0, outputPerMillion: 0,
                                  cacheWritePerMillion: 0, cacheReadPerMillion: 0),
                rateModel: model,
                isFastAlias: false,
                hasBaseRates: true
            )
        }
        let effectiveModel = pricingModel(for: model, at: timestamp)
        let canonicalModel = pricing.supplement.canonicalName(for: effectiveModel) ?? effectiveModel
        let isFastAlias = canonicalModel.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel
        let baseRates = pricing.resolve(model: rateModel)
        return RateResolution(
            rates: baseRates ?? pricing.resolve(model: effectiveModel),
            rateModel: rateModel,
            isFastAlias: isFastAlias,
            hasBaseRates: baseRates != nil
        )
    }

    /// Resolves a timestamped request's model. Callers pricing many requests should hold the result
    /// and reuse it only for requests with the same `pricingModel(for:at:)`.
    static func prepare(pricing: ModelPricing, model: String, at timestamp: Date) -> Prepared? {
        let resolution = resolveRates(pricing: pricing, model: model, at: timestamp)
        guard let rates = resolution.rates else { return nil }
        return Prepared(
            rates: adjusted(rates, model: resolution.rateModel),
            fastTier: resolution.isFastAlias && resolution.hasBaseRates
        )
    }

    /// Prices an already normalized request. Unlike native Codex rollout events, `tokens.input` here
    /// is non-cached input; cache reads/writes are disjoint buckets in `TokenBreakdown`.
    static func estimatedCost(pricing: ModelPricing, model: String, tokens: TokenBreakdown, at timestamp: Date) -> Double? {
        guard let prepared = prepare(pricing: pricing, model: model, at: timestamp) else { return nil }
        return cost(prepared: prepared, tokens: tokens)
    }

    static func cost(prepared: Prepared, tokens: TokenBreakdown) -> Double {
        var pricedTokens = tokens
        pricedTokens.isFast = prepared.fastTier
        return prepared.rates.costDollars(for: pricedTokens)
    }

    /// Lower-level entry point for the native scanner, which resolves its own rates so it can carry
    /// the per-event priority flag from the session log.
    static func cost(rates: ModelRates, tokens: TokenBreakdown, model: String, fastTier: Bool) -> Double {
        cost(prepared: Prepared(rates: adjusted(rates, model: model), fastTier: fastTier), tokens: tokens)
    }

    /// Applies every model-derived Codex adjustment in one pass so the slug is normalized once.
    private static func adjusted(_ rates: ModelRates, model: String) -> ModelRates {
        let base = datedBaseModel(model)
        var effective = rates
        if let longContext = longContextRates(base: base) {
            effective.inputAbove200kPerMillion = longContext.input
            effective.outputAbove200kPerMillion = longContext.output
            effective.cacheReadAbove200kPerMillion = longContext.cacheRead
            effective.longContextThresholdTokens = 272_000
        }
        // Either the model publishes no cache discount at all, or the catalog gave no explicit
        // cache-read rate. Both mean cached input is estimated at the full input rate.
        if hasNoCacheDiscount(base: base) || !rates.cacheReadIsExplicit {
            effective.cacheReadPerMillion = effective.inputPerMillion
            effective.cacheReadAbove200kPerMillion = effective.inputAbove200kPerMillion
        }
        effective.fastMultiplier = priorityMultiplier(base: base, rates: rates)
        return effective
    }

    static func priorityMultiplier(for model: String, rates: ModelRates) -> Double {
        priorityMultiplier(base: datedBaseModel(model), rates: rates)
    }

    private static func priorityMultiplier(base: String, rates: ModelRates) -> Double {
        switch base {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    private static func hasNoCacheDiscount(base: String) -> Bool {
        switch base {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func longContextRates(base: String) -> (input: Double, output: Double, cacheRead: Double)? {
        switch base {
        case "gpt-5.4": return (5, 22.5, 0.5)
        case "gpt-5.4-pro": return (60, 270, 60)
        case "gpt-5.5": return (10, 45, 1)
        case "gpt-5.5-pro": return (60, 270, 60)
        case "gpt-5.6-sol": return (10, 45, 1)
        case "gpt-5.6-terra": return (4, 18, 0.4)
        case "gpt-5.6-luna": return (0.4, 1.8, 0.04)
        // Above 272k: 2x input and cache, 1.5x output (developers.openai.com/api/docs/models/gpt-6-astra).
        case "gpt-6-astra": return (20, 75, 2)
        default: return nil
        }
    }

    /// Strips a trailing `-YYYY-MM-DD` or `-YYYYMMDD` snapshot suffix. Runs for every priced request,
    /// so it inspects characters directly instead of compiling a regex per call.
    static func datedBaseModel(_ model: String) -> String {
        // "-YYYY-MM-DD" then "-YYYYMMDD"; "d" marks a digit, "-" a literal dash.
        for pattern in ["-dddd-dd-dd", "-dddddddd"] where model.count > pattern.count {
            let suffix = model.suffix(pattern.count)
            let matches = zip(suffix, pattern).allSatisfy { character, token in
                token == "d" ? character.isNumber : character == token
            }
            if matches { return String(model.dropLast(pattern.count)) }
        }
        return model
    }
}
