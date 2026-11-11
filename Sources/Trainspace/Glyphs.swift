import CoreGraphics
import SwiftUI
import TrainspaceCore

/// Top-down train icons, front up (north), centred on the origin, in points.
/// Paths are immutable after creation, so sharing them across threads is safe.
enum Glyphs {
    /// A rounded car body; longer for commuter and intercity trains than for metro and light rail.
    static func body(for system: TransitSystem) -> CGPath {
        if system == .subway { return short }   // Baltimore's four-car trains
        return switch system.kind {
        case .commuter, .intercity: mainline
        case .rapidTransit: metro
        case .lightRail: short
        }
    }

    /// Where the headlight sits, relative to the centre.
    static func noseOffset(for system: TransitSystem) -> CGFloat {
        body(for: system).boundingBoxOfPath.minY + 2.2
    }

    nonisolated(unsafe) static let mainline = car(length: 17, width: 5.2)
    nonisolated(unsafe) static let metro = car(length: 13, width: 5)
    nonisolated(unsafe) static let short = car(length: 10.5, width: 4.8)

    /// Slightly tapered front, square back, so direction reads at a glance.
    private static func car(length: CGFloat, width: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let h = length / 2, w = width / 2
        p.move(to: CGPoint(x: 0, y: -h))
        p.addQuadCurve(to: CGPoint(x: w, y: -h + w * 1.3), control: CGPoint(x: w, y: -h))
        p.addLine(to: CGPoint(x: w, y: h - 0.9))
        p.addQuadCurve(to: CGPoint(x: w - 0.9, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: -w + 0.9, y: h))
        p.addQuadCurve(to: CGPoint(x: -w, y: h - 0.9), control: CGPoint(x: -w, y: h))
        p.addLine(to: CGPoint(x: -w, y: -h + w * 1.3))
        p.addQuadCurve(to: CGPoint(x: 0, y: -h), control: CGPoint(x: -w, y: -h))
        p.closeSubpath()
        return p
    }

    nonisolated(unsafe) static let arrow: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -6.5))
        p.addLine(to: CGPoint(x: 4.5, y: 5))
        p.addLine(to: CGPoint(x: 0, y: 2.5))
        p.addLine(to: CGPoint(x: -4.5, y: 5))
        p.closeSubpath()
        return p
    }()
}

/// A station drawn as a pill of LEDs: two across the track (one per direction), one row per
/// platform group. Sizes are in screen points.
enum StationPill {
    static let led: CGFloat = 6.4
    static let gap: CGFloat = 2.2
    static let padding: CGFloat = 1.9

    /// Screen rotation of the pill's LED axis: across the track, snapped to 45° so pills line up neatly.
    static func rotation(trackBearing: Double) -> Double {
        let b = trackBearing * .pi / 180
        let across = atan2(-cos(b), sin(b)) + .pi / 2
        var snapped = (across / (.pi / 4)).rounded() * (.pi / 4)
        while snapped > .pi / 2 { snapped -= .pi }
        while snapped <= -.pi / 2 { snapped += .pi }
        return snapped
    }

    static func size(groups: Int) -> CGSize {
        let rows = CGFloat(max(1, groups))
        return CGSize(width: led * 2 + gap + padding * 2, height: led * rows + gap * (rows - 1) + padding * 2)
    }

    /// - Parameter scale: drawing-space units per screen point (for stretched base-map paths).
    static func path(at c: CGPoint, groups: Int, rotation: Double, scale: CGFloat = 1) -> Path {
        let s = size(groups: groups)
        let rect = CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height)
        return Path(roundedRect: rect, cornerRadius: min(s.width, s.height) / 2)
            .applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(rotationAngle: rotation))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
    }

    static func ledCenter(at c: CGPoint, groups: Int, rotation: Double, group: Int, side: Int, scale: CGFloat = 1) -> CGPoint {
        let s = size(groups: groups)
        let local = CGPoint(x: (-s.width / 2 + padding + led / 2 + CGFloat(side) * (led + gap)) * scale,
                            y: (-s.height / 2 + padding + led / 2 + CGFloat(group) * (led + gap)) * scale)
        let p = local.applying(CGAffineTransform(rotationAngle: rotation))
        return CGPoint(x: c.x + p.x, y: c.y + p.y)
    }

    static func unlit(_ palette: Palette) -> RGBA { palette.isDark ? RGBA(hex: 0x2E2926) : RGBA(hex: 0x3A2D28) }
}
