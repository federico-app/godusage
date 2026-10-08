import Foundation

/// A scanned pairing QR code: `godusage://pair?code=…&server=https://api.godusage.com`, shown by a
/// Mac in Settings → Teams → iPhone and iPad.
struct PairingLink: Equatable {
    var code: String
    var server: URL

    enum Problem: Error, LocalizedError, Equatable {
        case notAPairingCode
        /// The code is for the other server (a DEV Mac and the production app, or the reverse).
        case otherServer(isDev: Bool)

        var errorDescription: String? {
            switch self {
            case .notAPairingCode:
                "That isn’t a GodUsage code. On your Mac, open Settings → Teams and choose Link iPhone or iPad."
            case .otherServer(let isDev):
                isDev
                    ? "This code is from GodUsage DEV. Scan it with the DEV build of this app, or show the code from the regular GodUsage."
                    : "This code is from the regular GodUsage. Scan it with the App Store build, or show the code from GodUsage DEV."
            }
        }
    }

    static func parse(_ text: String) throws(Problem) -> PairingLink {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "godusage", components.host == "pair",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let serverText = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = URL(string: serverText), server.scheme != nil
        else { throw .notAPairingCode }
        return PairingLink(code: code, server: server)
    }

    /// Throws unless the code is for `expected` (this build's server).
    func check(against expected: URL) throws(Problem) {
        guard server.host() != expected.host() else { return }
        throw .otherServer(isDev: server.host()?.contains("-dev") == true)
    }
}
