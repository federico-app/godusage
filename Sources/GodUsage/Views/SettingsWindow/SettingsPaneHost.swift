import SwiftUI

/// The Settings window's tabs. One case per preferences-style toolbar item; the raw value is the
/// persisted "last selected pane" key and the toolbar item identifier, so renaming a case is a
/// storage migration.
enum SettingsPane: String, CaseIterable, Sendable {
    case general
    case appearance
    case notifications
    case teams
    case advanced

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .teams: "Teams"
        case .advanced: "Advanced"
        }
    }

    var systemSymbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .teams: "person.2"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// The Settings window's SwiftUI root: exactly one pane, mounted fresh when the toolbar selection
/// changes — the whole window never holds more than the visible pane's tree. The pane sits in a
/// scroll view that only engages when the display can't fit the content (the window normally sizes
/// itself to the pane via the height callback).
struct SettingsPaneHost: View {
    /// The window opens this wide; the user can drag it between the minimum and maximum, and the
    /// window controller remembers the width. Panes fill whatever width the window has.
    static let defaultContentWidth: CGFloat = 560
    static let minimumContentWidth: CGFloat = 440
    static let maximumContentWidth: CGFloat = 960

    let pane: SettingsPane
    /// Reports the pane content's intrinsic height (a vertical scroll view proposes nil height, so
    /// the measurement is viewport-invariant). The window controller follows it.
    let onContentHeightChange: @MainActor (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical) {
            paneBody
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onContentHeightChange(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The same opaque page base the popover paints, so the shared card surfaces read identically
        // in both places.
        .background(Theme.traySurface)
    }

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .notifications: NotificationsSettingsPane()
        case .teams: TeamsSettingsPane()
        case .advanced: AdvancedSettingsPane()
        }
    }
}
