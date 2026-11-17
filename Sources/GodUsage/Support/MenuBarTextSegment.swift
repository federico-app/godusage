import AppKit
import SwiftUI

/// The colors one strip render uses. A plain strip is a template image (`template`: everything black,
/// macOS tints it); a strip with orange, green, or a badge is drawn twice, once per menu-bar
/// appearance (`light`, `dark`), and the image picks the matching one when it is drawn.
struct MenuBarPalette {
    let primary: Color
    let warning: Color
    let positive: Color
    let chipText: Color

    var dim: Color { primary.opacity(0.5) }

    func color(_ tone: MenuBarTone) -> Color {
        switch tone {
        case .primary: primary
        case .dim: dim
        case .warning, .chip: warning
        case .positive: positive
        }
    }

    static let template = MenuBarPalette(primary: .black, warning: .black, positive: .black, chipText: .white)
    /// The system orange per appearance; the light green is a shade darker than the system one so
    /// "▲1" stays legible on a light menu bar.
    static let light = MenuBarPalette(
        primary: .black,
        warning: Color(red: 1, green: 149 / 255, blue: 0),
        positive: Color(red: 40 / 255, green: 167 / 255, blue: 69 / 255),
        chipText: Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
    )
    static let dark = MenuBarPalette(
        primary: .white,
        warning: Color(red: 1, green: 159 / 255, blue: 10 / 255),
        positive: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255),
        chipText: Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
    )
}

struct MenuBarTextStrip: View {
    let content: MenuBarContent
    let palette: MenuBarPalette
    static let segmentSpacing: CGFloat = 11

    var body: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(content.groups, id: \.providerID) { group in
                MenuBarTextSegment(group: group, palette: palette)
            }
        }
        .foregroundStyle(palette.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

/// One provider/account segment shared by the flattened strip and its tooltip-width measurement.
struct MenuBarTextSegment: View {
    let group: MenuBarContent.Group
    let palette: MenuBarPalette

    var body: some View {
        HStack(spacing: 4) {
            MenuBarBadgedGlyph(icon: group.icon, badge: group.badge, isDimmed: group.isDimmed, palette: palette)
            if let resetText = group.resetText {
                Text(resetText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.dim)
            } else if !group.metrics.isEmpty {
                metricsView(group.metrics)
            }
        }
        .monospacedDigit()
        .foregroundStyle(palette.primary)
        .fixedSize()
    }

    /// One metric as a single large value, two stacked on two tight lines (much narrower than
    /// side-by-side), each behind its dimmed "S"/"W" when it has one.
    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1, let metric = metrics.first {
            line(metric, size: 12, weight: .bold)
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    line(metric, size: 9, weight: .semibold)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func line(_ metric: MenuBarContent.Metric, size: CGFloat, weight: Font.Weight) -> some View {
        let spans = metric.displaySpans
        if let chip = spans.first(where: { $0.tone == .chip }) {
            Text(chip.text)
                .font(.system(size: size - 1.5, weight: .bold))
                .foregroundStyle(palette.chipText)
                .padding(.horizontal, 3)
                // Trimmed to the digits so it clears the line above in the tight stack.
                .background(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(palette.warning)
                        .padding(.vertical, 0.5)
                )
                .padding(.top, 1)
        } else {
            spans.reduce(prefixText(metric.prefix, size: size)) { text, span in
                text + Text(span.text).foregroundStyle(palette.color(span.tone))
            }
            .font(.system(size: size, weight: weight))
        }
    }

    /// The small dimmed "S"/"W", or an empty run.
    private func prefixText(_ prefix: String?, size: CGFloat) -> Text {
        guard let prefix else { return Text("") }
        return Text(prefix)
            .font(.system(size: (size * 0.72).rounded(), weight: .semibold))
            .foregroundStyle(palette.dim)
            + Text(" ").font(.system(size: (size * 0.5).rounded()))
    }
}

/// The provider mark, faded when the account can't be used, with its badge in the top-trailing
/// corner. The badge sits in a ring cut out of the mark, so the menu bar's own background shows
/// around it in light and dark menu bars alike.
struct MenuBarBadgedGlyph: View {
    let icon: IconSource
    let badge: MenuBarBadge?
    let isDimmed: Bool
    let palette: MenuBarPalette

    /// Side length of the glyph box. Sized to fill the strip's height so the mark reads at the same
    /// scale as the dual-line metric block beside it (the single number is shorter), instead of
    /// floating small in the middle. `ProviderIconShape` already normalizes every mark to its true
    /// bounding box, so a near-zero `inset` here makes each provider fill this box uniformly.
    static let glyphSide: CGFloat = 16
    static let ringSide: CGFloat = 8
    static let dotSide: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topTrailing) {
            glyph.opacity(isDimmed ? 0.4 : 1)
            if let badge {
                Circle()
                    .frame(width: Self.ringSide, height: Self.ringSide)
                    .blendMode(.destinationOut)
                Circle()
                    .fill(badge == .useNow ? palette.positive : palette.warning)
                    .frame(width: Self.dotSide, height: Self.dotSide)
                    .offset(x: -(Self.ringSide - Self.dotSide) / 2, y: (Self.ringSide - Self.dotSide) / 2)
            }
        }
        .frame(width: Self.glyphSide, height: Self.glyphSide)
        .compositingGroup()
    }

    @ViewBuilder
    private var glyph: some View {
        if let mark = ProviderMarks.mark(for: icon.providerID) {
            ProviderIconShape(mark: mark, inset: 0.04)
                .fill(palette.primary)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else if icon.providerID == TeamsStore.menuBarGroupID {
            Image(systemName: ProviderMarks.symbolFallback(for: icon.providerID))
                .resizable()
                .scaledToFit()
                .foregroundStyle(palette.primary)
                .frame(width: Self.glyphSide - 2, height: Self.glyphSide - 2)
        } else {
            Circle().fill(palette.primary).frame(width: Self.glyphSide - 1, height: Self.glyphSide - 1)
        }
    }
}
