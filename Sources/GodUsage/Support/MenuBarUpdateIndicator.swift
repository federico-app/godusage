import SwiftUI

/// The update-available arrow that ends the menu-bar strip: a blue `arrow.down.circle.fill` while
/// the dashboard shows its "Update Available" banner (`UpdaterController.availableUpdateVersion`).
/// Clicking the status item still just opens the popover, where the banner's install button is.
enum MenuBarUpdateIndicator {
    /// The version the strip announces, or `nil` for no arrow. The arrow follows the banner's own
    /// state, and hides with the rest of the strip while screen-share privacy shows the wordmark.
    static func version(available: String?, concealUsage: Bool) -> String? {
        guard !concealUsage, let available, !available.isEmpty else { return nil }
        return available
    }

    /// VoiceOver and hover text for the arrow, e.g. "GodUsage 1.9.1 available".
    static func text(version: String) -> String {
        String(
            localized: "GodUsage \(version) available",
            comment: "Menu bar: VoiceOver and tooltip for the update arrow; the argument is the new version, e.g. 1.9.1"
        )
    }

    /// Gap between the last segment and the arrow, tighter than between segments since the arrow is
    /// a small glyph, not a provider segment.
    static let leadingSpacing: CGFloat = 7
}

/// The arrow itself, in the palette's accent blue (black in a template, though a strip with the
/// arrow is always drawn in color).
struct MenuBarUpdateGlyph: View {
    let palette: MenuBarPalette
    static let side: CGFloat = 13

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(palette.accent)
            .frame(width: Self.side, height: Self.side)
            .fixedSize()
    }
}

/// The GodUsage mark the strip leads with when the arrow has no provider segment to follow, so the
/// arrow never stands alone in the menu bar. Same mark and inset as `MenuBarIcon`, at the strip's
/// glyph size.
struct MenuBarAppMarkGlyph: View {
    let palette: MenuBarPalette

    var body: some View {
        if let mark = ProviderMarks.mark(for: "godusage") {
            ProviderIconShape(mark: mark, inset: 0.08)
                .fill(palette.primary)
                .frame(width: MenuBarBadgedGlyph.glyphSide, height: MenuBarBadgedGlyph.glyphSide)
        }
    }
}
