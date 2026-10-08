import AppKit
import CryptoKit

/// What the web sign-in hands back: a one-time code and the PKCE verifier that redeems it.
struct AppleSignInResult: Sendable, Equatable {
    var code: String
    var codeVerifier: String
}

enum AppleSignInError: Error, LocalizedError, Equatable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign in was cancelled."
        case .failed(let message):
            "Sign in with Apple failed: \(message)"
        }
    }
}

@MainActor
protocol AppleSignInProviding {
    func signIn() async throws -> AppleSignInResult
}

/// Sign in with Apple through the web, which works in every build. Developer ID builds cannot use
/// the native flow: their provisioning profiles never grant the Sign in with Apple entitlement.
/// Safari opens the teams backend's `/v1/auth/apple/start` (whatever the default browser is, so the
/// Apple ID signed in to Safari and its passkeys are used), Apple posts back to the backend, and the
/// backend returns to `<scheme>://auth` with a one-time code (see `docs/teams-backend.md`). The app's
/// URL handler hands that link to `receive(_:)`. The release and DEV apps listen on their own
/// schemes, so each gets back the sign-in it started.
@MainActor
final class AppleWebSignIn: AppleSignInProviding {
    /// The attempt waiting for its `<scheme>://auth` link.
    private static var pending: (state: String, continuation: CheckedContinuation<URL, Error>)?
    /// The backend keeps a sign-in request for 10 minutes.
    static let timeout: Duration = .seconds(600)

    private let baseURL: URL
    private let scheme: String
    private let open: @MainActor (URL) async throws -> Void

    init(
        baseURL: URL = TeamsAPIClient.defaultBaseURL(),
        scheme: String = AppChannel.urlScheme(),
        open: @escaping @MainActor (URL) async throws -> Void = AppleWebSignIn.openInSafari
    ) {
        self.baseURL = baseURL
        self.scheme = scheme
        self.open = open
    }

    func signIn() async throws -> AppleSignInResult {
        // A new attempt replaces one whose Safari tab was closed without finishing.
        Self.finish(state: nil, with: .failure(AppleSignInError.cancelled))
        let state = Self.randomToken()
        let verifier = Self.randomToken()
        guard let url = Self.startURL(baseURL: baseURL, state: state, codeVerifier: verifier, scheme: scheme) else {
            throw AppleSignInError.failed("The sign-in address is invalid.")
        }
        do {
            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                Self.pending = (state, continuation)
                Task { @MainActor in
                    do {
                        try await open(url)
                    } catch {
                        Self.finish(state: state, with: .failure(error))
                        return
                    }
                    try? await Task.sleep(for: Self.timeout)
                    Self.finish(state: state, with: .failure(AppleSignInError.failed("The sign-in took too long. Try again.")))
                }
            }
            return try Self.result(from: callbackURL, expectedState: state, codeVerifier: verifier, scheme: scheme)
        } catch AppleSignInError.cancelled {
            AppLog.info(.teams, "Sign in with Apple cancelled")
            throw AppleSignInError.cancelled
        } catch {
            AppLog.error(.teams, "Sign in with Apple failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Takes `<scheme>://auth?…` from the app's URL handler. Returns false for any other link. A link
    /// for an attempt that isn't the pending one (an old tab, or a forged link) is dropped.
    @discardableResult
    static func receive(_ url: URL) -> Bool {
        guard TeamInviteLink.schemes.contains(url.scheme?.lowercased() ?? ""), url.host()?.lowercased() == "auth" else { return false }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        guard let state, pending?.state == state else {
            AppLog.warn(.teams, "ignored a sign-in link that isn't for the sign-in in progress")
            return true
        }
        finish(state: state, with: .success(url))
        return true
    }

    /// Resumes the pending attempt, if it is `state`'s (or any, for nil).
    private static func finish(state: String?, with result: Result<URL, Error>) {
        guard let current = pending, state == nil || current.state == state else { return }
        pending = nil
        current.continuation.resume(with: result)
    }

    static func openInSafari(_ url: URL) async throws {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw AppleSignInError.failed("Safari isn't available on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: AppleSignInError.failed("Safari couldn't open the sign-in page: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func startURL(baseURL: URL, state: String, codeVerifier: String, scheme: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/auth/apple/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "scheme", value: scheme),
        ]
        return components?.url
    }

    /// Reads `<scheme>://auth?state=…&code=…` (or `&error=…`). A state that isn't this attempt's is
    /// refused, so a stray or forged callback cannot sign the app in.
    static func result(from url: URL, expectedState: String, codeVerifier: String, scheme: String) throws -> AppleSignInResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard url.scheme == scheme, url.host() == "auth", value("state") == expectedState else {
            throw AppleSignInError.failed("The sign-in response didn't match this sign-in. Try again.")
        }
        switch value("error") {
        case nil:
            break
        case "cancelled":
            throw AppleSignInError.cancelled
        case "invalid_token":
            throw AppleSignInError.failed("Apple's response couldn't be verified. Try again.")
        default:
            throw AppleSignInError.failed("Apple couldn't complete the sign-in. Try again.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AppleSignInError.failed("The sign-in response had no code. Try again.")
        }
        return AppleSignInResult(code: code, codeVerifier: codeVerifier)
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, base64url. `SystemRandomNumberGenerator` is cryptographically secure.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The signed-in session, in GodUsage's private 0600 file store (keyed by bundle id, so the dev
/// and release builds never share a session).
@MainActor
protocol TeamsSessionStoring {
    func load() throws -> TeamsSession?
    func save(_ session: TeamsSession?) throws
}

struct TeamsSessionFileStore: TeamsSessionStoring {
    private let store: any GodUsageOwnedSecretStoring
    private let service: String

    init(store: any GodUsageOwnedSecretStoring = GodUsageOwnedFileStore(), bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.montinovo.godusage") {
        self.store = store
        self.service = "teams-session.\(bundleIdentifier)"
    }

    func load() throws -> TeamsSession? {
        guard let text = try store.read(service: service), !text.isEmpty else { return nil }
        return try JSONDecoder().decode(TeamsSession.self, from: Data(text.utf8))
    }

    func save(_ session: TeamsSession?) throws {
        let text = try session.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try store.write(service: service, value: text)
    }
}
