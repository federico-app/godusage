import Foundation

/// A card name split for the dashboard: the provider (or a rename) leads, and the account it belongs
/// to follows in a quieter style ("Claude" + "Appload"). `detail` is the full account label
/// ("dev@appload.studio (Appload)") for the tooltip, so the email stays one hover away.
struct AccountDisplayName: Equatable, Sendable {
    let name: String
    /// The account's short label, or nil when the card needs none (one account, or a rename).
    var account: String? = nil
    /// The full account label, when it says more than `account`.
    var detail: String? = nil

    /// One line for plain text, such as the suggestion banner: "Claude (Appload)".
    var inline: String {
        account.map { "\(name) (\($0))" } ?? name
    }

    /// The short form of an account label. Labels are our own "email (Org Name)" format (see
    /// `DefaultAccountObserver.claudeIdentityLabel`), so the org name wins. A personal account's org
    /// is named after its email ("dev@example.com's Organization"), which says nothing more, so it
    /// falls back to the email, as does a label with no org.
    static func shortLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emails have no spaces, so the first " (" after an email starts the org.
        guard let open = trimmed.range(of: " ("), trimmed.hasSuffix(")") else { return trimmed }
        let email = String(trimmed[..<open.lowerBound])
        let org = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !email.contains(" ") else { return trimmed }
        if org.isEmpty || org.lowercased().hasPrefix(email.lowercased()) { return email }
        return org
    }

    /// The parts for a label: the short form leads, the full label rides in `detail` when they differ.
    static func labeled(_ name: String, label: String, suffix: String? = nil) -> AccountDisplayName {
        let short = shortLabel(label)
        let account = suffix.map { "\(short) · \($0)" } ?? short
        let full = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountDisplayName(name: name, account: account, detail: full == short ? nil : full)
    }
}
