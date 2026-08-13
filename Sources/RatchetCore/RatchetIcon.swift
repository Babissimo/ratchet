// Sources/RatchetCore/RatchetIcon.swift
import AppKit

/// Ratchet's mark: a clock face inside a ratchet bezel, drawn procedurally rather than shipped
/// as bitmap/PDF assets. This is a direct Swift port of the "curve" bezel at tooth-rise 5 with
/// "long-thin" hands from `design/icons/generate.py` — that script is the design-exploration
/// tool (SVG, many variants); this is the one combination that shipped, kept in sync by hand
/// since the two are a handful of constants apart and diverging would be worse than duplicating.
///
/// All geometry lives on a 64x64 design grid with the origin at the centre; `mark` and `appTile`
/// scale that grid to whatever size is requested, so a single definition serves the menu bar (an
/// 18pt template image), dialog icons, and the Dock/`.icns` tile alike.
public enum RatchetIcon {
    private static let gridSize: CGFloat = 64
    private static let center = CGPoint(x: 32, y: 32)

    // Bezel: six teeth, tips at the edge of the grid, a smooth curve easing tangentially off the
    // ring between them so the only hard edges are the six radial tooth faces.
    private static let tipRadius: CGFloat = 31.0
    private static let band: CGFloat = 7.0       // rim thickness, held constant across tooth sizes
    private static let toothRise: CGFloat = 5.0  // tooth height; ring/face move inward with it
    private static let toothCount = 6
    private static let phaseDegrees: CGFloat = -14.0
    private static let slopeEase: CGFloat = 2.6  // higher hugs the ring longer before lifting
    private static let curveSteps = 32

    private static var bodyRadius: CGFloat { tipRadius - toothRise }
    private static var faceRadius: CGFloat { bodyRadius - band }

    // Hands: "long-thin" — narrow, reaching close to the rim. Fractions are where the *visible*
    // tip lands (the outside of the round cap, not the line's endpoint) — see `handLength`.
    private static let handWidth: CGFloat = 4.0
    private static let hourTipFraction: CGFloat = 0.70
    private static let minuteTipFraction: CGFloat = 0.94
    private static let hourDegrees: CGFloat = 120.0
    private static let minuteDegrees: CGFloat = 0.0
    private static let tipClearance: CGFloat = 0.8   // keeps the cap off the rim

    private static let appTileCornerRadius: CGFloat = 15.0
    private static let appTileMarkScale: CGFloat = 0.70
    public static let trackingGreen = NSColor(srgbRed: 0x4C / 255, green: 0xAF / 255, blue: 0x3E / 255, alpha: 1)
    public static let appTileFieldGreen = NSColor(srgbRed: 0x3E / 255, green: 0x9A / 255, blue: 0x31 / 255, alpha: 1)

    // Dock tile texture. Ported by hand from the approved SVG prototype
    // (`design/icons/generate_textured.py`'s "soft gradient" variant) rather than rasterizing
    // that SVG directly — cairosvg (the only SVG-to-PNG path available while building this)
    // doesn't implement the filter primitives the prototype relies on (feComponentTransfer,
    // feTurbulence), so it renders a flat gradient with no grain, edge shading, or engraving.
    // These constants and the two filter-equivalent helpers below (`drawGrain`,
    // `drawInsetShadow`) are what stand in for those SVG filters.
    private static let tileRect = NSRect(x: 2, y: 2, width: 60, height: 60)
    private static let tileTopGreen = NSColor(srgbRed: 0x63 / 255, green: 0xC8 / 255, blue: 0x53 / 255, alpha: 1)
    private static let tileHighlightGreen = NSColor(srgbRed: 0xB6 / 255, green: 0xF0 / 255, blue: 0xA6 / 255, alpha: 1)
    private static let tileShadeGreen = NSColor(srgbRed: 0x0E / 255, green: 0x2E / 255, blue: 0x0B / 255, alpha: 1)
    private static let markEngraveShadow = NSColor(srgbRed: 0x1F / 255, green: 0x5A / 255, blue: 0x19 / 255, alpha: 1)

    /// A point at radius `r` from the grid centre, `deg` degrees clockwise from 12 o'clock —
    /// matching `polar()` in `generate.py` so the two stay comparable term-for-term.
    private static func polar(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }

    /// The bezel outline: six straight tooth faces alternating with six curved slopes that leave
    /// the ring tangentially (radius eases off `bodyRadius` with zero initial slope), then a
    /// circular hole cut with the even-odd winding rule for the clock face.
    private static func bezelPath() -> NSBezierPath {
        let pitch = 360.0 / CGFloat(toothCount)
        let path = NSBezierPath()
        for i in 0..<toothCount {
            let a = phaseDegrees + CGFloat(i) * pitch
            let tip = polar(tipRadius, a)
            if i == 0 {
                path.move(to: tip)
            } else {
                path.line(to: tip)
            }
            path.line(to: polar(bodyRadius, a))
            for j in 1...curveSteps {
                let u = CGFloat(j) / CGFloat(curveSteps)
                let r = bodyRadius + toothRise * pow(u, slopeEase)
                path.line(to: polar(r, a + pitch * u))
            }
        }
        path.close()
        path.appendOval(in: NSRect(
            x: center.x - faceRadius, y: center.y - faceRadius,
            width: faceRadius * 2, height: faceRadius * 2
        ))
        path.windingRule = .evenOdd
        return path
    }

    /// Where a hand's visible tip lands: `frac * r`, clamped so the round cap never overlaps the
    /// face's edge, then pulled back by half the stroke width since `NSBezierPath` measures a
    /// round-capped line to its centreline endpoint, not the cap's outer edge.
    private static func handLength(fraction: CGFloat, radius: CGFloat) -> CGFloat {
        let tip = min(fraction * radius, radius - tipClearance)
        return max(tip - handWidth / 2, 1.0)
    }

    private static func handsPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = handWidth
        path.lineCapStyle = .round
        for (fraction, degrees) in [(hourTipFraction, hourDegrees), (minuteTipFraction, minuteDegrees)] {
            path.move(to: center)
            path.line(to: polar(handLength(fraction: fraction, radius: faceRadius), degrees))
        }
        return path
    }

    /// Draws bezel then hands into the current graphics context, scaled from the 64x64 design
    /// grid to `size`. Shared by `mark` and `appTile` so the two never drift.
    private static func draw(bezelColor: NSColor, handColor: NSColor, size: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: size / gridSize)
        transform.concat()

        bezelColor.setFill()
        bezelPath().fill()

        let hands = handsPath()
        handColor.setStroke()
        hands.stroke()

        context.restoreGraphicsState()
    }

    /// The bare mark (bezel + hands) on a transparent background, at `size` points.
    ///
    /// For the idle/template state, `bezelColor`/`handColor` can be anything opaque — a template
    /// image's RGB is discarded, only alpha is used, so pass `.black` for both. For the tracking
    /// state, pass real colors (`trackingGreen` and `.white` is what ships) and leave
    /// `image.isTemplate` false, since a template image would flatten the color away.
    public static func mark(size: CGFloat, bezelColor: NSColor, handColor: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            draw(bezelColor: bezelColor, handColor: handColor, size: size)
            return true
        }
    }

    /// The Dock/`.icns` treatment: a textured green tile (vertical gradient, an off-axis top-right
    /// highlight, edge shading for a 3D-button read, and film grain) with the white mark engraved
    /// into it, centred and scaled down. Deliberately inverts the tray relationship (which is a
    /// colored mark on whatever background the menu bar has) so the two never look like the same
    /// asset at two sizes.
    public static func appTile(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            let scale = size / gridSize
            context.saveGraphicsState()
            let outer = NSAffineTransform()
            outer.scale(by: scale)
            outer.concat()

            drawTileBackground(context: context.cgContext, scale: scale)

            // translate(32 32) scale(0.70) translate(-32 -32), matching generate.py's app_icon.
            let mark = NSAffineTransform()
            mark.translateX(by: gridSize / 2, yBy: gridSize / 2)
            mark.scale(by: appTileMarkScale)
            mark.translateX(by: -gridSize / 2, yBy: -gridSize / 2)
            mark.concat()

            // The mark scale above compounds with the outer `scale`, so shadows drawn inside it
            // need the combined factor, not just `scale` on its own.
            drawEngravedMark(context: context.cgContext, scale: scale * appTileMarkScale)

            context.restoreGraphicsState()
            return true
        }
    }

    // MARK: - Dock tile texture

    private static func cgGradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map(\.0.cgColor) as CFArray,
            locations: stops.map(\.1)
        )
    }

    private static func drawTileBackground(context: CGContext, scale: CGFloat) {
        let clipPath = CGPath(
            roundedRect: tileRect, cornerWidth: appTileCornerRadius, cornerHeight: appTileCornerRadius,
            transform: nil
        )

        context.saveGState()
        context.addPath(clipPath)
        context.clip()

        // Base vertical gradient: lighter at the top, the flat tile's field green at the bottom.
        if let gradient = cgGradient([(tileTopGreen, 0), (appTileFieldGreen, 1)]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: tileRect.midX, y: tileRect.minY),
                end: CGPoint(x: tileRect.midX, y: tileRect.maxY), options: []
            )
        }

        // Off-axis highlight near the top right. A linear gradient only carries stops along one
        // axis, so this "third point" is a radial hot spot layered on top rather than a true
        // multi-directional gradient — the standard way to fake one in a 2-stop-per-axis system.
        let highlightCenter = CGPoint(
            x: tileRect.minX + tileRect.width * 0.80, y: tileRect.minY + tileRect.height * 0.16
        )
        if let gradient = cgGradient([
            (tileHighlightGreen.withAlphaComponent(0.85), 0), (tileHighlightGreen.withAlphaComponent(0), 1),
        ]) {
            context.drawRadialGradient(
                gradient, startCenter: highlightCenter, startRadius: 0,
                endCenter: highlightCenter, endRadius: tileRect.width * 0.62, options: []
            )
        }

        // Side vignette: darker at the left/right edges, transparent through the middle — half of
        // the "3D button" read, the other half is `drawInsetShadow` below darkening the bottom.
        if let gradient = cgGradient([
            (tileShadeGreen.withAlphaComponent(0.32), 0), (tileShadeGreen.withAlphaComponent(0), 0.16),
            (tileShadeGreen.withAlphaComponent(0), 0.84), (tileShadeGreen.withAlphaComponent(0.32), 1),
        ]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: tileRect.minX, y: tileRect.midY),
                end: CGPoint(x: tileRect.maxX, y: tileRect.midY), options: []
            )
        }

        drawGrain(in: tileRect, context: context)
        context.restoreGState()

        drawInsetShadow(
            clip: clipPath, context: context, color: tileShadeGreen,
            offset: CGSize(width: 0, height: 3.2), blur: 3.0, opacity: 0.38, scale: scale
        )
    }

    /// A small, fast, seeded PRNG (xorshift64*) so grain is identical across builds — matches the
    /// SVG prototype's `feTurbulence seed="7"` in spirit, deterministic rather than reproducing
    /// its exact noise function.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    /// Fine speckle standing in for the SVG prototype's `feTurbulence`-based grain, which cairosvg
    /// can't render (see the doc comment on the texture constants above): small low-alpha dots at
    /// deterministic random positions, rather than a true noise field — visually equivalent at the
    /// low opacity this ships at.
    private static func drawGrain(in rect: NSRect, context: CGContext, opacity: CGFloat = 0.08, dotCount: Int = 1400) {
        var rng = SeededGenerator(seed: 7)
        context.saveGState()
        for _ in 0..<dotCount {
            let x = CGFloat.random(in: rect.minX...rect.maxX, using: &rng)
            let y = CGFloat.random(in: rect.minY...rect.maxY, using: &rng)
            let r = CGFloat.random(in: 0.12...0.34, using: &rng)
            let alpha = CGFloat.random(in: 0.15...1.0, using: &rng) * opacity
            context.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        context.restoreGState()
    }

    /// The inner-shadow trick behind both the tile's edge shading and the mark's engraving: fill
    /// the *inverse* of `clip` (a huge rect minus `clip`, even-odd) with a drop shadow. The inverse
    /// shape itself is invisible (it's clipped away), but the shadow it casts bleeds inward across
    /// `clip`'s boundary — the standard CoreGraphics stand-in for SVG's invert/blur/offset/flood
    /// inner-shadow filter chain, which needs `feComponentTransfer` (also unsupported by cairosvg).
    ///
    /// `offset`/`blur` are given in 64-unit grid space, matching every other measurement in this
    /// file, but `CGContext.setShadow` — unlike fills, strokes, and gradients — does *not* scale
    /// its parameters with the CTM. Without multiplying by `scale` here, a blur/offset tuned to
    /// look right at grid scale renders as a near-invisible fraction of a device pixel once the
    /// grid is scaled up to icon size; this was found by isolating the trick on a plain shape
    /// with no scale transform, where the same numbers looked exactly as intended.
    private static func drawInsetShadow(
        clip: CGPath, context: CGContext, color: NSColor, offset: CGSize, blur: CGFloat, opacity: CGFloat,
        scale: CGFloat
    ) {
        let bigRect = tileRect.insetBy(dx: -60, dy: -60)
        let inverse = CGMutablePath()
        inverse.addRect(bigRect)
        inverse.addPath(clip)

        let scaledOffset = CGSize(width: offset.width * scale, height: offset.height * scale)
        let scaledBlur = blur * scale

        context.saveGState()
        context.addPath(clip)
        context.clip(using: .evenOdd)
        context.setShadow(offset: scaledOffset, blur: scaledBlur, color: color.withAlphaComponent(opacity).cgColor)
        context.addPath(inverse)
        context.setFillColor(color.withAlphaComponent(0.9).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// The white mark, engraved into the tile rather than lifted off it: the flat fill/stroke,
    /// then a dark inset shadow along its upper inner edge and a faint light catch along its
    /// lower inner edge, each clipped to the mark's own silhouette (bezel and hands separately,
    /// so the bezel's even-odd face cutout isn't affected by the hands' clip).
    private static func drawEngravedMark(context: CGContext, scale: CGFloat) {
        draw(bezelColor: .white, handColor: .white, size: gridSize)

        let bezelClip = bezelPath().asCGPath
        let handsClip = handsPath().asCGPath.copy(
            strokingWithWidth: handWidth, lineCap: .round, lineJoin: .round, miterLimit: 10
        )

        for clip in [bezelClip, handsClip] {
            drawInsetShadow(
                clip: clip, context: context, color: markEngraveShadow,
                offset: CGSize(width: 0, height: 1.0), blur: 1.0, opacity: 0.55, scale: scale
            )
            drawInsetShadow(
                clip: clip, context: context, color: .white,
                offset: CGSize(width: 0, height: -0.6), blur: 0.8, opacity: 0.40, scale: scale
            )
        }
    }
}

private extension NSBezierPath {
    /// Manual `NSBezierPath` -> `CGPath` conversion. The built-in `NSBezierPath.cgPath` needs
    /// macOS 14+; this works back to the package's macOS 13 deployment target.
    var asCGPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
