import AppKit
import AuthenticationServices
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
/// The system sign-in sheet opens the teams backend's `/v1/auth/apple/start`, Apple posts back to the
/// backend, and the backend returns to `godusage://auth` with a one-time code (see
/// `docs/teams-backend.md`).
@MainActor
final class AppleWebSignIn: NSObject, AppleSignInProviding {
    private let baseURL: URL
    private var session: ASWebAuthenticationSession?

    init(baseURL: URL = TeamsAPIClient.defaultBaseURL()) {
        self.baseURL = baseURL
    }

    func signIn() async throws -> AppleSignInResult {
        guard session == nil else { throw AppleSignInError.failed("A sign-in is already in progress.") }
        let state = Self.randomToken()
        let verifier = Self.randomToken()
        guard let url = Self.startURL(baseURL: baseURL, state: state, codeVerifier: verifier) else {
            throw AppleSignInError.failed("The sign-in address is invalid.")
        }
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(TeamInviteLink.scheme),
                completionHandler: Self.completionHandler(resuming: continuation)
            )
            session.presentationContextProvider = self
            // Reuse the browser's Apple ID session, so a signed-in Safari needs only a confirmation.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AppleSignInError.failed("The sign-in window couldn't open."))
            }
        }
        session = nil
        do {
            return try Self.result(from: callbackURL, expectedState: state, codeVerifier: verifier)
        } catch AppleSignInError.cancelled {
            AppLog.info(.teams, "Sign in with Apple cancelled")
            throw AppleSignInError.cancelled
        } catch {
            AppLog.error(.teams, "Sign in with Apple failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// The session calls this on an AuthenticationServices XPC queue, not the main thread. Built
    /// outside the main-actor `signIn()` so it is not main-actor-isolated: a main-actor closure run
    /// there trips Swift's isolation check and crashes the app.
    nonisolated static func completionHandler(
        resuming continuation: CheckedContinuation<URL, Error>
    ) -> @Sendable (URL?, Error?) -> Void {
        { callbackURL, error in
            if let callbackURL {
                continuation.resume(returning: callbackURL)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: AppleSignInError.cancelled)
            } else {
                continuation.resume(throwing: AppleSignInError.failed(error?.localizedDescription ?? "No response."))
            }
        }
    }

    static func startURL(baseURL: URL, state: String, codeVerifier: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/auth/apple/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
        ]
        return components?.url
    }

    /// Reads `godusage://auth?state=…&code=…` (or `&error=…`). A state that isn't this attempt's is
    /// refused, so a stray or forged callback cannot sign the app in.
    static func result(from url: URL, expectedState: String, codeVerifier: String) throws -> AppleSignInResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard url.scheme == TeamInviteLink.scheme, url.host() == "auth", value("state") == expectedState else {
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

extension AppleWebSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
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
