import SwiftUI

/// The dashboard's usage suggestion: the most urgent piece of advice about which provider to use
/// right now (see `UsageAdvisor`). Closing it shows the next one, if any; a dismissed suggestion
/// stays away until its situation changes.
struct UsageSuggestionBanner: View {
    let suggestion: UsageSuggestion
    let onDismiss: () -> Void

    var body: some View {
        DismissableHintCard(
            systemImage: suggestion.kind.systemImage,
            title: suggestion.title,
            message: suggestion.message,
            tint: TotalSpendPalette.color(for: suggestion.family),
            buttonTitle: suggestion.kind == .planUnderused ? "Open Plans" : nil,
            action: { TeamsWindowLink.open() },
            onDismiss: onDismiss
        )
    }
}

private extension UsageSuggestion.Kind {
    var systemImage: String {
        switch self {
        case .claimReset, .resetExpiring, .resetsAvailable: "arrow.counterclockwise.circle"
        case .useBeforeReset: "hourglass"
        case .switchProvider: "arrow.left.arrow.right.circle"
        case .planUnderused: "creditcard"
        }
    }
}
