import Foundation

/// Whether a provider's daily spend history belongs to this Mac or to the whole account. Every
/// provider with shared spend tiles declares this explicitly, so Teams never adds an account-wide
/// source once per device.
struct UsageHistoryDescriptor: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable {
        case machineLocal
        case accountWide
    }

    let scope: Scope
    let estimatedCost: Bool
    let sourceNote: String
}

extension WidgetDescriptor {
    /// Classifies the provider's normalized daily history beside its other machine-facing exports.
    func exportingHistory(
        scope: UsageHistoryDescriptor.Scope,
        estimatedCost: Bool,
        sourceNote: String
    ) -> WidgetDescriptor {
        var copy = self
        copy.historyResource = UsageHistoryDescriptor(
            scope: scope,
            estimatedCost: estimatedCost,
            sourceNote: sourceNote
        )
        return copy
    }
}
