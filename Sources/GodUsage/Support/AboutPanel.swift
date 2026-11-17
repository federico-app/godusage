import AppKit

/// Presents the standard macOS About panel for the footer menu's "About GodUsage" item.
///
/// As a menu-bar accessory app, GodUsage is not the active app while the popover is showing, so the
/// app is activated first — otherwise the panel would open behind whatever app currently owns the
/// foreground. The panel pulls the app icon, name, and version (`CFBundleShortVersionString` — the
/// same string `AppInfo.version` surfaces in the footer) straight from the bundle; we only supply the
/// credits line, naming the maintainers and linking the GitHub repo.
enum AboutPanel {
    @MainActor
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Centered, secondary-styled credits: the original author, the upstream maintainers, and this
    /// fork's GitHub repo. The standard panel renders `.link`-attributed runs as clickable.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        // Whole localized sentences; the names are then linked wherever the translation put them.
        let author = "Robin Ebers", mert = "Mert", david = "David", github = "GitHub"
        let text = [
            String(localized: "Created by \(author)", comment: "About panel credits; the argument is a person's name"),
            String(localized: "Maintained also by \(mert) & \(david)", comment: "About panel credits; the arguments are people's names"),
            "",
            String(localized: "Open source on \(github)", comment: "About panel credits; the argument is GitHub"),
        ].joined(separator: "\n")
        let credits = NSMutableAttributedString(string: text, attributes: base)
        link(author, "https://itsbyrob.in/x", in: credits)
        link(mert, "https://github.com/validatedev", in: credits)
        link(david, "https://github.com/davidarny", in: credits)
        link(github, "https://github.com/federico-app/godusage", in: credits)
        return credits
    }

    /// Links the first occurrence of `name` in `credits`.
    private static func link(_ name: String, _ urlString: String, in credits: NSMutableAttributedString) {
        let range = (credits.string as NSString).range(of: name)
        guard range.location != NSNotFound, let url = URL(string: urlString) else { return }
        credits.addAttribute(.link, value: url, range: range)
    }
}
