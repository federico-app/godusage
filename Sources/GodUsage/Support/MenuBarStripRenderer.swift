import AppKit
import SwiftUI

/// One native tooltip region over the flattened Text strip, expressed in the rendered image's point
/// coordinates. `StatusItemController` maps it into the status button without adding child views, so
/// the whole item keeps its existing click target.
struct MenuBarToolTipRegion: Equatable {
    let displayName: String
    let rect: CGRect
}

/// The flattened menu-bar image plus any native tooltip regions that belong over it.
struct MenuBarStripPresentation {
    let image: NSImage
    let toolTipRegions: [MenuBarToolTipRegion]
}

/// Renders the Text-style menu-bar strip (`MenuBarContent`) into a template `NSImage` for the
/// `MenuBarExtra` label: provider mark + bare value for a single metric, or a tight labeled stack for
/// two. Black-on-clear so macOS tints it for light/dark; sized to its natural width. The image is built
/// outside the `label:` view builder (an `ImageRenderer` inline there throws obscure errors).
@MainActor
enum MenuBarStripRenderer {
    /// Last render, memoized on (content, style). The label view re-evaluates on every snapshot
    /// write — several times per refresh pass — but the strip's visible content rarely changes.
    /// Returning the same `NSImage` instance lets SwiftUI skip the status-item update, and keeps
    /// `ImageRenderer` (which retains a little memory per run on macOS) to actual visual changes.
    private static var lastRender: (
        content: MenuBarContent,
        style: MenuBarStyle,
        presentation: MenuBarStripPresentation?
    )?

    /// The strip image for the given content and style, or `nil` when the content renders nothing
    /// in that style (caller falls back to the app icon). Memoized: equal inputs return the
    /// previously rendered instance.
    static func image(for content: MenuBarContent, style: MenuBarStyle) -> NSImage? {
        presentation(for: content, style: style)?.image
    }

    /// The flattened strip image and its tooltip regions. Text carries one per account plus the update
    /// arrow's. Bars carry only the arrow's: they flatten metrics across providers and therefore have
    /// no segment-to-account geometry to label.
    static func presentation(for content: MenuBarContent, style: MenuBarStyle) -> MenuBarStripPresentation? {
        if let lastRender, lastRender.style == style,
           lastRender.content.isRenderEquivalent(to: content, style: style)
        {
            AppLog.debug(.menubar, "strip cache hit")
            return lastRender.presentation
        }
        AppLog.debug(.menubar, "strip cache miss (rendering)")
        let presentation: MenuBarStripPresentation?
        switch style {
        case .text:
            presentation = textPresentation(for: content)
        case .bars:
            presentation = barsPresentation(for: content)
        }
        lastRender = (content, style, presentation)
        return presentation
    }

    /// The pinned-metrics strip, or `nil` when nothing is pinned or no pinned metric has data yet
    /// (caller falls back to the app icon).
    ///
    /// The render is trimmed to its visible pixels: the view's anti-aliasing padding and the provider
    /// glyph's normalization inset would otherwise ship as transparent margins, widening the status
    /// item past its artwork (the menu bar already pads every item, so baked-in margins read as an
    /// extra-large gap next to neighboring items).
    static func textImage(for content: MenuBarContent) -> NSImage? {
        textPresentation(for: content)?.image
    }

    private static func textPresentation(for content: MenuBarContent) -> MenuBarStripPresentation? {
        guard !content.isEmpty,
              let image = stripImage(colored: content.needsColor(style: .text), trim: true, view: { palette in
                  MenuBarTextStrip(content: content, palette: palette)
              })
        else { return nil }
        image.accessibilityDescription = content.accessibilityText
        return MenuBarStripPresentation(
            image: image,
            toolTipRegions: textToolTipRegions(for: content, imageSize: image.size)
        )
    }

    /// Renders a strip view. Without color it is one template image. With color it is drawn once
    /// per menu-bar appearance, and the image draws the variant matching the appearance it is drawn
    /// in, so it follows a light or dark menu bar (and a wallpaper change) without re-rendering.
    private static func stripImage<V: View>(
        colored: Bool, trim: Bool, @ViewBuilder view: (MenuBarPalette) -> V
    ) -> NSImage? {
        let scale: CGFloat = 2
        func render(_ palette: MenuBarPalette) -> CGImage? {
            let renderer = ImageRenderer(content: view(palette))
            renderer.scale = scale
            return renderer.cgImage
        }
        guard colored else {
            guard let rendered = render(.template) else { return nil }
            let cgImage = trim ? (trimmedToVisibleContent(rendered) ?? rendered) : rendered
            let image = NSImage(cgImage: cgImage, size: pointSize(cgImage, scale: scale))
            image.isTemplate = true
            return image
        }
        guard let lightRender = render(.light), let darkRender = render(.dark) else { return nil }
        // Both variants share one layout, so one crop fits both.
        let bounds = trim ? visibleBounds(of: lightRender) : nil
        let light = bounds.flatMap { lightRender.cropping(to: $0) } ?? lightRender
        let dark = bounds.flatMap { darkRender.cropping(to: $0) } ?? darkRender
        let image = NSImage(size: pointSize(light, scale: scale), flipped: false) { rect in
            let drawing = NSAppearance.currentDrawing()
            let match = drawing.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            let isDark = match == .darkAqua || match == .vibrantDark
            NSGraphicsContext.current?.cgContext.draw(isDark ? dark : light, in: rect)
            return true
        }
        // Draw on every pass: a cached bitmap would keep the appearance it was first drawn in.
        image.cacheMode = .never
        return image
    }

    private static func pointSize(_ image: CGImage, scale: CGFloat) -> NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// Measures each segment using the exact view shared by the flattened strip, then partitions the
    /// final trimmed image at the midpoint of each inter-segment gap. Scaling the natural widths back
    /// onto the trimmed image absorbs the small transparent edge crop without changing the strip
    /// renderer or leaving dead hover gaps between adjacent accounts. The update arrow is one more
    /// region at the end ("GodUsage 1.9.1 available"); with no account segment before it, the whole
    /// strip (app mark plus arrow) is that one region.
    private static func textToolTipRegions(
        for content: MenuBarContent,
        imageSize: NSSize
    ) -> [MenuBarToolTipRegion] {
        guard imageSize.width > 0 else { return [] }
        let updateText = content.updateVersion.map(MenuBarUpdateIndicator.text(version:))
        if content.groups.isEmpty {
            guard let updateText else { return [] }
            return [MenuBarToolTipRegion(
                displayName: updateText, rect: CGRect(origin: .zero, size: imageSize)
            )]
        }
        var segments = content.groups.map { group in
            (toolTip: group.toolTip, view: AnyView(MenuBarTextSegment(group: group, palette: .template)))
        }
        if let updateText {
            segments.append((toolTip: updateText, view: AnyView(MenuBarUpdateGlyph(palette: .template))))
        }
        let widths = segments.compactMap { segment -> CGFloat? in
            let renderer = ImageRenderer(content: segment.view)
            renderer.scale = 2
            return renderer.cgImage.map { CGFloat($0.width) / renderer.scale }
        }
        guard widths.count == segments.count else { return [] }

        // The gap before each segment: the arrow sits closer than the account segments do.
        let gaps = segments.indices.map { index -> CGFloat in
            if index == 0 { return 0 }
            return updateText != nil && index == segments.count - 1
                ? MenuBarUpdateIndicator.leadingSpacing
                : MenuBarTextStrip.segmentSpacing
        }
        let naturalWidth = widths.reduce(0, +) + gaps.reduce(0, +)
        guard naturalWidth > 0 else { return [] }
        let scale = imageSize.width / naturalWidth

        var segmentX: CGFloat = 0
        return segments.indices.map { index in
            segmentX += gaps[index]
            let width = widths[index]
            let minX = index == 0 ? 0 : (segmentX - gaps[index] / 2) * scale
            let maxX = index == segments.count - 1
                ? imageSize.width
                : (segmentX + width + gaps[index + 1] / 2) * scale
            segmentX += width
            return MenuBarToolTipRegion(
                displayName: segments[index].toolTip,
                rect: CGRect(x: minX, y: 0, width: max(0, maxX - minX), height: imageSize.height)
            )
        }
    }

    /// Crops fully transparent margins off a rendered strip, or `nil` when the image has no visible
    /// pixels (caller keeps the untrimmed render).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// The bounding box of pixels with non-zero alpha, in pixel coordinates (origin at the top-left
    /// row, matching `CGImage.cropping(to:)`), or `nil` for a fully transparent image.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The compact Bars glyph (≤4 bounded-metric bars), or `nil` when no pinned metric has a fill
    /// and no update is pending.
    static func barsImage(for content: MenuBarContent) -> NSImage? {
        barsPresentation(for: content)?.image
    }

    /// The Bars glyph plus, when the update arrow ends it, one tooltip region over the arrow. The
    /// bars themselves carry no regions: they flatten metrics across providers.
    private static func barsPresentation(for content: MenuBarContent) -> MenuBarStripPresentation? {
        let fractions = content.bars.map(\.fraction)
        let warnings = content.bars.map(\.isOverPace)
        let exhausted = content.groups.filter(\.isDimmed)
        let hasUsage = !fractions.isEmpty || !exhausted.isEmpty
        guard hasUsage || content.updateVersion != nil else { return nil }
        let image = stripImage(colored: content.needsColor(style: .bars), trim: false) { palette in
            HStack(spacing: MenuBarUpdateIndicator.leadingSpacing) {
                HStack(spacing: 8) {
                    if !fractions.isEmpty {
                        // A bar over pace fills in orange.
                        MenuBarBars(fractions: fractions, warnings: warnings, side: 18, palette: palette)
                    }
                    ForEach(exhausted, id: \.providerID) { group in
                        MenuBarTextSegment(group: group, palette: palette)
                    }
                    if !hasUsage {
                        MenuBarAppMarkGlyph(palette: palette)
                    }
                }
                if content.updateVersion != nil {
                    MenuBarUpdateGlyph(palette: palette)
                }
            }
        }
        guard let image else { return nil }
        image.accessibilityDescription = content.accessibilityText
        return MenuBarStripPresentation(image: image, toolTipRegions: barsToolTipRegions(for: content, imageSize: image.size))
    }

    /// The arrow's region: its glyph plus half the gap before it, at the untrimmed image's end (or the
    /// whole image when only the app mark precedes it).
    private static func barsToolTipRegions(for content: MenuBarContent, imageSize: NSSize) -> [MenuBarToolTipRegion] {
        guard let version = content.updateVersion, imageSize.width > 0 else { return [] }
        let hasUsage = !content.bars.isEmpty || content.groups.contains(where: \.isDimmed)
        let width = hasUsage
            ? min(imageSize.width, MenuBarUpdateGlyph.side + MenuBarUpdateIndicator.leadingSpacing / 2)
            : imageSize.width
        return [MenuBarToolTipRegion(
            displayName: MenuBarUpdateIndicator.text(version: version),
            rect: CGRect(x: imageSize.width - width, y: 0, width: width, height: imageSize.height)
        )]
    }

    /// The screen-share privacy stand-in: the wordmark instead of usage values, shown while
    /// `MenuBarPrivacyStore.concealUsage` is true so a shared or recorded screen never carries token
    /// counts or spend. Deterministic, so rendered once; `nil` only if `ImageRenderer` fails entirely
    /// (caller falls back to the app icon).
    static let privacyImage: NSImage? = {
        let renderer = ImageRenderer(content: MenuBarPrivacyLabel())
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = String(
            localized: "GodUsage, usage hidden while the screen is shared",
            comment: "VoiceOver: the menu bar item while screen sharing hides the usage numbers"
        )
        return image
    }()

    /// Last-resort icon if the brand mark fails to load.
    static let fallbackIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "GodUsage"
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// The brand gauge mark plus wordmark drawn in place of the strip while screen-share privacy is
/// concealing usage. Same black-on-clear template treatment, glyph box, and type size as a
/// single-metric Text strip, so the swap doesn't jump the menu bar's rhythm.
private struct MenuBarPrivacyLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            // The same mark and inset as `MenuBarIcon` (the art carries its own margin), sized to the
            // strip's glyph box so the swap keeps the provider-glyph scale.
            if let mark = ProviderMarks.mark(for: "godusage") {
                ProviderIconShape(mark: mark, inset: 0.08)
                    .fill(Color.black)
                    .frame(width: 16, height: 16)
            }
            Text("GodUsage")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

/// Draws up to four horizontal usage bars into a compact square — a 1:1 port of the Tauri edition's
/// tray bars: track 0.16 / fill 1.0 / remainder 0.24 opacity of the strip color (black in a template,
/// so macOS tints it), a rounded leading edge with a small rounded moving edge, and near-full
/// quantization so a 97% bar still shows a visible tail. A bar over pace fills in orange.
private struct MenuBarBars: View {
    let fractions: [Double]
    let warnings: [Bool]
    let side: CGFloat
    let palette: MenuBarPalette

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(4, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(palette.primary.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(i < warnings.count && warnings[i] ? palette.warning : palette.primary)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(palette.primary.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Pure fill geometry for the Bars glyph, factored out so the near-full quantization and minimum-visible
/// remainder rules are unit-testable. A 1:1 port of the Tauri edition's tray math.
enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    /// Quantize near-full (0.7–1.0) bars by remainder in 15% steps, so a nearly-full bar still leaves a
    /// visible tail instead of reading as 100%.
    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}
