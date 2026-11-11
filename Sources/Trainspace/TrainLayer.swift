import SwiftUI
import TrainspaceCore

/// Remembers which side each label sat on, so labels don't hop between frames.
final class LabelMemory {
    var slots: [String: LabelSlot] = [:]
}

/// Pre-rendered label bitmaps. Drawing a cached image is several times cheaper per frame
/// than laying out text, and train labels rarely change.
@MainActor
final class LabelImageCache {
    static let shared = LabelImageCache()
    private var images: [String: (image: Image, size: CGSize)] = [:]
    private var paletteKey: Palette?

    /// - Parameter fontName: an agency typeface, or nil for the map's monospaced labels.
    func label(_ primary: String, _ secondary: String?, primaryColor: RGBA, secondaryColor: RGBA, palette: Palette,
               fontName: String? = nil) -> (image: Image, size: CGSize)? {
        if paletteKey != palette || images.count > 800 {
            images.removeAll(keepingCapacity: true)
            paletteKey = palette
        }
        let key = primary + "|" + (secondary ?? "") + (primaryColor == palette.textPrimary ? "!" : "") + "|" + (fontName ?? "")
        if let hit = images[key] { return hit }
        var text = Text(primary).foregroundColor(primaryColor.color)
        if let secondary { text = text + Text(" " + secondary).foregroundColor(secondaryColor.color) }
        let font = fontName.map { Font.custom($0, size: Typeface.labelSize + 0.5) } ?? Typeface.label
        let renderer = ImageRenderer(content: text.font(font).tracking(Typeface.labelTracking).fixedSize())
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let entry = (Image(decorative: cg, scale: 2), CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        images[key] = entry
        return entry
    }
}

/// Screen rects other layers have claimed (station names), shared with the label layout.
final class SharedObstacles {
    var rects: [CGRect] = []
}

struct TrainLayer: View {
    let model: AppModel
    let projection: Projection
    let palette: Palette
    /// The info corner's area: labels avoid it and trains beneath it are dimmed.
    let infoRect: CGRect?
    let shared: SharedObstacles

    @State private var memory = LabelMemory()

    var body: some View {
        let fps = model.powerMode.fps
        TimelineView(.animation(minimumInterval: 1 / max(1, fps), paused: fps <= 0)) { timeline in
            Canvas { ctx, size in
                Diagnostics.framesDrawn += 1
                let t = (model.clockOverride ?? timeline.date).timeIntervalSince1970
                if model.settings.glyph == .stationLights, let lights = model.stationLights, let rail = model.rail {
                    StationLightsRenderer(settings: model.settings, palette: palette, projection: projection, lights: lights, rail: rail,
                                          colorFor: { model.color(for: $0, palette: palette) })
                        .draw(model.tracker.snapshot(at: t).filter { model.isVisible($0.report) }, at: t, in: &ctx, size: size, scrim: infoRect)
                    return
                }
                TrainRenderer(settings: model.settings, palette: palette, projection: projection,
                              stale: model.isStale, nearestID: model.nearestID,
                              colorFor: { model.color(for: $0, palette: palette) },
                              labelFor: { model.label($0) })
                    .draw(model.tracker.snapshot(at: t).filter { model.isVisible($0.report) },
                          in: &ctx, size: size, obstacles: obstacles(size), scrim: infoRect, memory: memory)
            }
        }
        .allowsHitTesting(false)
    }

    private func obstacles(_ size: CGSize) -> [CGRect] {
        let crosshair = CGRect(x: size.width / 2 - 12, y: size.height / 2 - 12, width: 24, height: 24)
        return [crosshair] + shared.rects + (infoRect.map { [$0] } ?? [])
    }
}

struct TrainRenderer {
    let settings: WallpaperSettings
    let palette: Palette
    let projection: Projection
    let stale: Bool
    let nearestID: String?
    let colorFor: (TrainReport) -> RGBA
    let labelFor: (TrainReport) -> String

    func draw(_ trains: [DisplayTrain], in ctx: inout GraphicsContext, size: CGSize,
              obstacles: [CGRect], scrim: CGRect?, memory: LabelMemory) {
        let bounds = CGRect(origin: .zero, size: size)
        let cull = bounds.insetBy(dx: -40, dy: -40)
        let dim = (stale ? 0.4 : 1) * settings.brightness

        var drawn = 0
        defer { MainActor.assumeIsolated { Diagnostics.trainsDrawn = drawn } }
        var labelRequests: [LabelRequest] = []
        var labelInfo: [String: (train: DisplayTrain, image: Image, size: CGSize)] = [:]

        // Mainline under metro, so dense downtown metro stays readable; stable order otherwise.
        let ordered = trains.sorted { ($0.report.system.isMainline ? 0 : 1, $0.id) < ($1.report.system.isMainline ? 0 : 1, $1.id) }
        for t in ordered {
            let pt = projection.point(t.position)
            guard cull.contains(pt), t.opacity > 0 else { continue }
            drawn += 1
            let alpha = t.opacity * dim * (t.report.isScheduled ? 0.85 : 1)
            let color = colorFor(t.report)

            if settings.trailMinutes > 0 { drawTrail(t, head: pt, color: color, alpha: alpha, in: &ctx) }
            if settings.pulse && t.pulse > 0 && !t.report.isScheduled { drawPulse(at: pt, pulse: t.pulse, color: color, alpha: alpha, in: &ctx) }
            drawGlyph(t, at: pt, color: color, alpha: alpha, in: &ctx)

            if t.id == nearestID {
                let r: CGFloat = settings.glyph == .train ? 14 : 10
                ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                           with: .color(palette.textPrimary.with(alpha: 0.55 * alpha).color), lineWidth: 0.8)
            }

            if settings.labelMode != .off, bounds.contains(pt), let label = labelImage(t) {
                let distance = hypot(pt.x - size.width / 2, pt.y - size.height / 2)
                let priority = t.id == nearestID ? -1 : Double(distance) + (t.report.isScheduled ? 400 : 0)
                labelRequests.append(LabelRequest(id: t.id, anchor: pt,
                                                  size: CGSize(width: label.size.width + 2, height: max(12, label.size.height)),
                                                  priority: priority, gap: settings.glyph == .train ? 11 : 8))
                labelInfo[t.id] = (t, label.image, label.size)
            }
        }

        if let scrim { punchOut(scrim, in: &ctx) }
        guard !labelRequests.isEmpty else { return }
        let placed = LabelLayout.layout(labelRequests, obstacles: obstacles, bounds: bounds.insetBy(dx: 6, dy: 6),
                                        previous: memory.slots, glyphRadius: 5)
        var slots: [String: LabelSlot] = [:]
        for label in placed {
            guard let info = labelInfo[label.id] else { continue }
            slots[label.id] = label.slot
            var c = ctx
            c.opacity = info.train.opacity * dim
            c.draw(info.image, in: CGRect(x: label.rect.minX + 1, y: label.rect.midY - info.size.height / 2,
                                          width: info.size.width, height: info.size.height))
        }
        memory.slots = slots
    }

    // MARK: Pieces

    /// Fades out whatever was drawn under the info corner, with soft edges (stacked insets are
    /// much cheaper per frame than a blur).
    private func punchOut(_ rect: CGRect, in ctx: inout GraphicsContext) {
        var c = ctx
        c.blendMode = .destinationOut
        let steps = 8
        for i in 0..<steps {
            let inset = CGFloat(steps - i) * 7 - 20
            let r = rect.insetBy(dx: inset, dy: inset)
            c.fill(Path(roundedRect: r, cornerRadius: 40), with: .color(.black.opacity(0.22)))
        }
    }

    private func labelImage(_ t: DisplayTrain) -> (image: Image, size: CGSize)? {
        let primary = t.id == nearestID ? palette.textPrimary : RGBA.mix(palette.textSecondary, palette.textPrimary, 0.35)
        let secondary: String? = settings.labelMode == .trainDestination ? t.report.headsign?.uppercased() : nil
        let name = labelFor(t.report), tertiary = palette.textTertiary, palette = palette
        return MainActor.assumeIsolated {
            LabelImageCache.shared.label(name, secondary, primaryColor: primary, secondaryColor: tertiary, palette: palette,
                                         fontName: nil)
        }
    }

    /// Trail fades from transparent (oldest) to ~half strength at the train, drawn in a few bands.
    private func drawTrail(_ t: DisplayTrain, head: CGPoint, color: RGBA, alpha: Double, in ctx: inout GraphicsContext) {
        var points = t.trail.map { projection.point($0.position) }
        points.append(head)
        guard points.count >= 2 else { return }
        let segments = points.count - 1
        let bands = min(6, segments)
        let peak = palette.isDark ? 0.55 : 0.65
        for b in 0..<bands {
            let start = b * segments / bands
            let end = (b + 1) * segments / bands
            guard end > start else { continue }
            var path = Path()
            path.move(to: points[start])
            for i in (start + 1)...end { path.addLine(to: points[i]) }
            let f = Double(b + 1) / Double(bands)
            ctx.stroke(path, with: .color(color.with(alpha: pow(f, 1.6) * peak * alpha).color),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawPulse(at p: CGPoint, pulse: Double, color: RGBA, alpha: Double, in ctx: inout GraphicsContext) {
        let r = 4 + (1 - pulse) * 14
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .color(color.with(alpha: pulse * 0.45 * alpha).color), lineWidth: 1)
    }

    private func drawGlyph(_ t: DisplayTrain, at p: CGPoint, color: RGBA, alpha: Double, in ctx: inout GraphicsContext) {
        let heading = (t.heading ?? t.report.bearingDeg ?? 0) * .pi / 180
        let scheduled = t.report.isScheduled
        // Bloom: wide and soft on dark, a faint halo on light. Estimates glow less.
        let glowR: CGFloat = settings.glyph == .train ? 14 : 13
        let glowAlpha = (settings.glyph == .train ? 0.55 : 1) * (0.12 + 0.28 * palette.glow) * alpha * (scheduled ? 0.4 : 1)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(Gradient(colors: [color.with(alpha: glowAlpha).color, color.with(alpha: 0).color]),
                                       center: p, startRadius: 0, endRadius: glowR))

        let transform = CGAffineTransform(rotationAngle: heading).concatenating(CGAffineTransform(translationX: p.x, y: p.y))
        switch settings.glyph {
        case .light:
            let dot = Path(ellipseIn: CGRect(x: p.x - 2.8, y: p.y - 2.8, width: 5.6, height: 5.6))
            if scheduled {
                ctx.stroke(dot, with: .color(color.with(alpha: alpha).color), lineWidth: 1.3)
            } else {
                ctx.fill(dot, with: .color(color.with(alpha: alpha).color))
                if palette.isDark {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)),
                             with: .color(RGBA(1, 1, 1, 0.75 * alpha).color))
                }
            }
        case .stationLights:
            break   // drawn by StationLightsRenderer
        case .arrow:
            let shape = Path(Glyphs.arrow).applying(transform)
            if scheduled {
                ctx.stroke(shape, with: .color(color.with(alpha: alpha).color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            } else {
                ctx.fill(shape, with: .color(color.with(alpha: alpha).color))
            }
        case .train:
            let system = t.report.system
            let shape = Path(Glyphs.body(for: system)).applying(transform)
            // A thin halo in the ground colour separates the car from track and trails.
            ctx.stroke(shape, with: .color(palette.land.with(alpha: 0.9 * alpha).color), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            if scheduled {
                // Timetable estimates are drawn hollow.
                ctx.fill(shape, with: .color(palette.land.with(alpha: alpha).color))
                ctx.stroke(shape, with: .color(color.with(alpha: alpha).color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            } else {
                ctx.fill(shape, with: .color(color.with(alpha: alpha).color))
                // Headlight at the front.
                let nose = CGPoint(x: 0, y: Glyphs.noseOffset(for: system)).applying(transform)
                let light = palette.isDark ? RGBA(1, 1, 1, 0.85 * alpha) : palette.land.with(alpha: 0.9 * alpha)
                ctx.fill(Path(ellipseIn: CGRect(x: nose.x - 1.1, y: nose.y - 1.1, width: 2.2, height: 2.2)), with: .color(light.color))
            }
        }
    }
}

/// Station Lights: each train lights the LED at its station, in its line's colour. Steady while
/// it's at the station; blinking while it's on its way in or out. Two trains on one LED take turns.
struct StationLightsRenderer {
    let settings: WallpaperSettings
    let palette: Palette
    let projection: Projection
    let lights: StationLights
    let rail: RailNetwork
    let colorFor: (TrainReport) -> RGBA

    func draw(_ trains: [DisplayTrain], at t: TimeInterval, in ctx: inout GraphicsContext, size: CGSize, scrim: CGRect?) {
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
        let zoom = projection.radiusNM / Geo.nmPerMile
        var lit: [StationLights.LED: [(RGBA, StationLights.Phase, Double)]] = [:]
        for d in trains where d.opacity > 0.05 {
            guard let (led, phase) = lights.led(for: d.report, position: d.position, heading: d.heading),
                  let station = rail.stations[safe: led.station],
                  // Only stations the base map draws a pill for.
                  settings.systems.contains(station.system), SchematicGeometry.showsStation(rank: station.rank, zoomMiles: zoom),
                  view.contains(projection.point(station.position)) else { continue }
            lit[led, default: []].append((colorFor(d.report), phase, d.opacity))
        }
        MainActor.assumeIsolated { Diagnostics.trainsDrawn = lit.values.reduce(0) { $0 + $1.count } }
        let brightness = settings.brightness
        let r = StationPill.led / 2
        for (led, entries) in lit {
            guard let node = lights.nodes[led.station] else { continue }
            let (color, phase, opacity) = entries[Int(t / 1.5) % entries.count]
            // Blink: a soft on/off about once a second, never fully dark so the LED stays findable.
            let blink = phase == .inTransit && settings.pulse ? 0.18 + 0.82 * pow(0.5 + 0.5 * cos(t * 2 * .pi / 1.1), 2) : 1
            let a = opacity * brightness * blink
            let c = StationPill.ledCenter(at: projection.point(rail.stations[led.station].position), groups: node.groups.count,
                                          rotation: StationPill.rotation(trackBearing: node.trackBearing), group: led.group, side: led.side)
            let glowR = r * (palette.isDark ? 3.2 : 2.4)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [color.with(alpha: (palette.isDark ? 0.55 : 0.35) * a).color, color.with(alpha: 0).color]),
                                           center: c, startRadius: 0, endRadius: glowR))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [RGBA.mix(color, RGBA(1, 1, 1), 0.5).with(alpha: a).color, color.with(alpha: a).color]),
                                           center: CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.3), startRadius: 0, endRadius: r))
        }
        if let scrim {
            var c = ctx
            c.blendMode = .destinationOut
            c.fill(Path(roundedRect: scrim.insetBy(dx: -8, dy: -8), cornerRadius: 40), with: .color(.black.opacity(0.85)))
        }
    }
}
