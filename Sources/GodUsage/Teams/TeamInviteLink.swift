import Foundation

/// Reads an invite code out of whatever the user has: the `godusage://join/<code>` link the invite
/// page opens, the `https://…/join/<code>` link someone pasted, or the bare code.
enum TeamInviteLink {
    /// The release app's scheme and the DEV app's (see `AppChannel.urlScheme`). Either is read, so a
    /// link pasted from the other channel still yields its code.
    static let schemes = ["godusage", "godusage-dev"]

    private static func isCode(_ value: String) -> Bool {
        (8...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func code(from url: URL) -> String? {
        let parts: [String]
        if schemes.contains(url.scheme?.lowercased() ?? "") {
            // godusage://join/<code>: "join" is the host, the code is the path.
            guard url.host()?.lowercased() == "join" else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 2, components[0] == "join" else { return nil }
            parts = [components[1]]
        } else {
            return nil
        }
        guard parts.count == 1, let code = parts.first, isCode(code) else { return nil }
        return code
    }

    static func code(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCode(trimmed) { return trimmed }
        return URL(string: trimmed).flatMap(code(from:))
    }
}
