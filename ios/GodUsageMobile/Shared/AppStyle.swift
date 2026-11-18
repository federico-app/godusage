import SwiftUI
import UIKit

/// Provider brand colors, the same as the Mac's `TotalSpendPalette`: keyed by provider id only, so a
/// provider keeps its color everywhere. Brands whose mark is black flip for dark mode.
enum ProviderPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),
        "codex": hex(0x10A37F),
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),
        "openrouter": hex(0x6467F2),
        "antigravity": hex(0x4285F4),
        "copilot": hex(0xA855F7),
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6),
    ]

    private static let fallback: [Color] = [hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(uiColor: uiColor(value))
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }

    private static func uiColor(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The Mac's This Week's Limit colors: orange and green text dark enough to read on their tint.
enum WeekLimitColors {
    /// Today's use past its budget: a darker orange, so white text reads on it.
    static let over = Color(uiColor: UIColor(red: 0.71, green: 0.28, blue: 0.06, alpha: 1))
    static let noticeText = adaptive(light: UIColor(red: 0.64, green: 0.32, blue: 0.04, alpha: 1), dark: .systemOrange)
    static let positiveText = adaptive(light: UIColor(red: 0.14, green: 0.44, blue: 0.23, alpha: 1), dark: .systemGreen)
    /// The gold of the crown and the trophy.
    static let gold = adaptive(light: UIColor(red: 0.72, green: 0.53, blue: 0.04, alpha: 1), dark: UIColor(red: 0.93, green: 0.74, blue: 0.27, alpha: 1))

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension View {
    /// A card like the Mac panel's: a rounded grouped background.
    func cardSurface() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "DEV" in an orange capsule in dev-channel builds, as on the Mac's cost card.
struct DevBuildBadge: View {
    var body: some View {
        #if DEV_CHANNEL
        Text(verbatim: "DEV")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Color.orange, in: Capsule())
            .accessibilityLabel(Text("GodUsage DEV build"))
        #endif
    }
}

/// A failed load, above a tab's content.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardSurface()
    }
}

/// The account menu in each tab's toolbar: who is signed in, and Sign Out.
struct AccountMenu: View {
    var model: TeamsModel
    @State private var confirmingSignOut = false

    var body: some View {
        Menu {
            if let name = model.session?.user.displayName {
                Text("Signed in as \(name).")
            }
            Button("Sign Out", role: .destructive) { confirmingSignOut = true }
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
        .confirmationDialog("Sign out of GodUsage on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("You can link it again with a new code from your Mac.")
        }
    }
}
