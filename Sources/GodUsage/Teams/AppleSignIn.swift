import AppKit
import AuthenticationServices

struct AppleSignInResult: Sendable {
    var identityToken: String
    /// Apple shares the name only on the very first authorization; later sign-ins get nil.
    var displayName: String?
}

enum AppleSignInError: Error, LocalizedError {
    case cancelled
    case notConfigured
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign in was cancelled."
        case .notConfigured:
            "This build isn’t set up for Sign in with Apple. Use a build signed with a provisioning profile that includes Sign in with Apple."
        case .failed(let message):
            "Sign in with Apple failed: \(message)"
        }
    }
}

@MainActor
protocol AppleSignInProviding {
    func signIn() async throws -> AppleSignInResult
}

/// Runs one Sign in with Apple request. The sheet attaches to the key window (Settings or Teams).
@MainActor
final class AppleSignInCoordinator: NSObject, AppleSignInProviding {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var controller: ASAuthorizationController?

    func signIn() async throws -> AppleSignInResult {
        guard continuation == nil else { throw AppleSignInError.failed("A sign-in is already in progress.") }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AppleSignInResult, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential?.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        MainActor.assumeIsolated {
            guard let token else {
                AppLog.error(.teams, "Sign in with Apple returned no identity token")
                finish(.failure(AppleSignInError.failed("Apple returned no identity token.")))
                return
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.success(AppleSignInResult(identityToken: token, displayName: trimmed?.isEmpty == false ? trimmed : nil)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let nsError = error as NSError
        MainActor.assumeIsolated {
            guard nsError.domain == ASAuthorizationError.errorDomain else {
                AppLog.error(.teams, "Sign in with Apple failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
                finish(.failure(AppleSignInError.failed(nsError.localizedDescription)))
                return
            }
            switch ASAuthorizationError.Code(rawValue: nsError.code) {
            case .canceled:
                AppLog.info(.teams, "Sign in with Apple cancelled")
                finish(.failure(AppleSignInError.cancelled))
            case .unknown:
                // What a build without the Sign in with Apple entitlement (or its profile) gets.
                AppLog.error(.teams, "Sign in with Apple unavailable (code \(nsError.code)): the build is likely missing the entitlement or provisioning profile")
                finish(.failure(AppleSignInError.notConfigured))
            default:
                AppLog.error(.teams, "Sign in with Apple failed (code \(nsError.code)): \(nsError.localizedDescription)")
                finish(.failure(AppleSignInError.failed(nsError.localizedDescription)))
            }
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
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
