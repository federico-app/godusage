import AppKit
import SwiftUI

/// Details' two rates: PACE NOW, in the plan's color when it's running hot or well under, and the pace
/// that lasts until the end of the working day.
struct LivePaceRateTiles: View {
    /// Nil before there's a rate to show.
    let now: String?
    let nowTone: LivePace.Tone
    let allowed: String
    let until: String

    var body: some View {
        HStack(spacing: 6) {
            tile(String(localized: "Pace Now", comment: "Tile label, shown uppercase: the current spending rate."), value: now ?? "–",
                 style: now == nil ? AnyShapeStyle(.secondary) : toneStyle)
            tile(String(localized: "To Last Until \(until)", comment: "Tile label, shown uppercase: the rate that lasts until the end of the working day (a time)."),
                 value: allowed, style: AnyShapeStyle(.primary))
        }
    }

    private var toneStyle: AnyShapeStyle {
        switch nowTone {
        case .hot: AnyShapeStyle(WeekLimitColors.noticeText)
        case .cool: AnyShapeStyle(WeekLimitColors.positiveText)
        case .neutral: AnyShapeStyle(.primary)
        }
    }

    private func tile(_ title: String, value: String, style: AnyShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased(with: AppLocale.current))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Today's working hours on one line, and on the right who else's hours count: up to three initials,
/// then "+N", then "shared". The names are in the tooltip.
struct LivePaceHoursLine: View {
    let spans: [DateInterval]
    let sharedWith: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text(LivePaceDetails.hours(spans))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if !sharedWith.isEmpty { shared }
        }
    }

    private var shared: some View {
        let (shown, more) = LivePaceDetails.avatars(sharedWith)
        let label = LivePaceDetails.sharedWith(sharedWith)
        return HStack(spacing: 4) {
            HStack(spacing: -4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, name in InitialsCircle(name: name) }
            }
            if more > 0 {
                Text(verbatim: "+\(more)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("shared", comment: "After the initials of the people whose working hours count with yours.").font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize()
        .hoverTooltip(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A name's initials on a soft circle in the name's own hue.
private struct InitialsCircle: View {
    let name: String

    var body: some View {
        let hue = LivePaceDetails.hue(name)
        Text(LivePaceDetails.initials(name))
            .font(.system(size: 7.5, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Self.adaptive(
                light: NSColor(hue: hue, saturation: 0.65, brightness: 0.45, alpha: 1),
                dark: NSColor(hue: hue, saturation: 0.3, brightness: 0.95, alpha: 1)
            ))
            .frame(width: 19, height: 19)
            .background(Circle().fill(Self.adaptive(
                light: NSColor(hue: hue, saturation: 0.18, brightness: 0.95, alpha: 1),
                dark: NSColor(hue: hue, saturation: 0.45, brightness: 0.38, alpha: 1)
            )))
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
