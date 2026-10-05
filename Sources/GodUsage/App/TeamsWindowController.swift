import AppKit
import SwiftUI

/// Opens the Teams leaderboard window from anywhere (gear menu, Teams settings, invite links).
/// Installed by `StatusItemController`, like `SettingsWindowLink` and `MemoryWindowLink`.
@MainActor
public enum TeamsWindowLink {
    static var openHandler: (@MainActor () -> Void)?

    public static func open() {
        openHandler?()
    }
}

/// A plain titled window that also closes on Esc, ⌘W, and ⌘Q (see `SettingsWindow` for why ⌘Q
/// closes the window instead of quitting while it is up).
final class TeamsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !(firstResponder is NSText) { // Esc
            close()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the Teams window with the same discipline as Settings and Memory: built lazily on first
/// open, torn down on close, and its frame remembered.
@MainActor
final class TeamsWindowController: NSObject, NSWindowDelegate {
    private let container: AppContainer
    private let activation: ActivationPolicyCoordinator
    private var window: TeamsWindow?
    private var hosting: NSHostingController<AnyView>?

    private static let frameAutosaveName = "GodUsageTeamsWindow"
    private static let defaultContentSize = NSSize(width: 820, height: 620)
    private static let minimumContentSize = NSSize(width: 620, height: 460)

    init(container: AppContainer, activation: ActivationPolicyCoordinator = .shared) {
        self.container = container
        self.activation = activation
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        activation.acquire(.teamsWindow, reason: "teams window opened")
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let hosting = NSHostingController(rootView: AnyView(TeamsLeaderboardView().environment(container)))
        hosting.sizingOptions = []
        self.hosting = hosting

        let window = TeamsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.title = "Teams"
        window.contentMinSize = Self.minimumContentSize
        window.contentViewController = hosting
        window.setContentSize(Self.defaultContentSize)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        self.window = window
        AppLog.info(.teams, "Teams window opened")
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        activation.release(.teamsWindow)
        window?.delegate = nil
        // Release outside the delegate callback; see `MemoryWindowController.windowWillClose`.
        Task { @MainActor [weak self] in
            self?.window?.contentViewController = nil
            self?.hosting = nil
            self?.window = nil
        }
    }
}
