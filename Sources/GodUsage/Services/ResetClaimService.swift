import Foundation
import SwiftUI

/// The outcome of a rate-limit reset claim, as the resets popover renders it. Each provider collapses
/// its own protocol answers into these (see `CodexResetClaimService.outcome(fromConsume:)` and
/// `ClaudeProvider.resetClaimOutcome(from:)`).
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    /// The server took the claim but couldn't confirm it landed (Claude only). The request id is kept,
    /// so a retry can only confirm this claim, never spend a second reset.
    case unconfirmed
    /// A reset exists but can't be used right now, e.g. a cooldown or a paused grant (Claude only).
    case unavailableNow(until: Date?)
    case failed
}

/// Claims one rate-limit reset from the resets popover — the app's only provider-API writes, so every
/// claim is an explicit two-click user action. Never throws: every failure is logged and collapsed to
/// an outcome the popover can render.
@MainActor
protocol ResetClaimService: AnyObject, Sendable {
    /// `false` renders the timeline read-only (no "Use").
    var isClaimable: Bool { get }
    /// Replaces the confirm card's default explanation line.
    var confirmDetail: String? { get }
    /// Claims the reset the picked node stands for. `redeemRequestID` is the popover's idempotency
    /// key for that node, reused for every retry so a retry can never spend twice.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome
}

extension ResetClaimService {
    var isClaimable: Bool { true }
    var confirmDetail: String? { nil }
}

/// The post-claim forced refresh every provider shares. The forced refresh returns `.skipped` when
/// another refresh already owns the provider — and that in-flight probe may carry *pre-claim* usage —
/// so retry until this refresh actually runs (bounded). A `.failed` probe is retried a few times too —
/// a transient flake right after the claim must not strand pre-claim meters behind a success banner —
/// before giving up loudly (the provider error already shows on the card, so the staleness isn't
/// silent).
@MainActor
enum ResetClaimRefresh {
    /// 300 one-second waits: must outlast not just the provider's slowest refresh (~45s of request
    /// budgets) but also the store's refresh deadline (`defaultProviderRefreshTimeout`, 150s) PLUS a
    /// timed-out attempt's straggler hold (`hungRefreshProviderIDs`), during which every probe returns
    /// `.skipped` — giving up sooner would strand pre-claim meters behind a success banner exactly when
    /// the provider was already struggling.
    static let maxAttempts = 300

    static func run(dataStore: WidgetDataStore?, providerID: String, tag: String) async {
        var failures = 0
        for attempt in 0..<maxAttempts {
            guard let dataStore else { return }
            switch await dataStore.refresh(providerID: providerID, force: true) {
            case .refreshed, .cacheHit, .backedOff:
                return
            case .failed:
                failures += 1
                guard failures < 3 else {
                    AppLog.error(LogTag.plugin(tag), "\(providerID) post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            case .skipped:
                AppLog.info(LogTag.plugin(tag), "\(providerID) post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        AppLog.error(LogTag.plugin(tag), "\(providerID) post-claim refresh kept being skipped; meters may lag until the next cycle")
    }
}

/// Exact-card routing for the app's provider writes. Every card owns a service built from that
/// runtime's own credentials and HTTP client, so a row can never claim a reset against whichever
/// login of that provider happened to be registered first.
@MainActor
final class ResetClaimRouter {
    private let servicesByProviderID: [String: any ResetClaimService]

    init(servicesByProviderID: [String: any ResetClaimService]) {
        self.servicesByProviderID = servicesByProviderID
    }

    func service(for providerID: String) -> (any ResetClaimService)? {
        servicesByProviderID[providerID]
    }
}

/// Hands the claim service to the resets popover through the environment: `nil` (the default —
/// previews, share-card renders, reorder previews, providers without a claim) renders the timeline
/// read-only with no "Use" affordance.
private struct ResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: (any ResetClaimService)? = nil
}

extension EnvironmentValues {
    var resetClaim: (any ResetClaimService)? {
        get { self[ResetClaimServiceKey.self] }
        set { self[ResetClaimServiceKey.self] = newValue }
    }
}
