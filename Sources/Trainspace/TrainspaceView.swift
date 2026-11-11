import CoreImage
import MapKit
import SwiftUI
import TrainspaceCore

/// One display's wallpaper: base map → track and stations → trains → info corner.
/// Used as a single view for previews and snapshots. The desktop windows host the three
/// stacks in separate layers (see `WallpaperController`) so animating trains never forces
/// the static map to redraw.
struct TrainspaceView: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets
    @State private var shared = SharedObstacles()

    var body: some View {
        ZStack(alignment: .topLeading) {
            BaseStack(model: model, size: size, insets: insets, shared: shared)
            TrafficStack(model: model, size: size, insets: insets, shared: shared)
            InfoStack(model: model, size: size, insets: insets)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Re-resolves the palette once a minute (it follows the sun) and hands it to its content.
struct PaletteReader<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: (Palette) -> Content

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let palette = model.palette(at: model.clockOverride ?? timeline.date)
            content(palette)
                .environment(\.colorScheme, palette.isDark ? .dark : .light)
        }
    }
}

/// Static layer: base map, track, stations and range rings. Redraws only when location, zoom,
/// style, options or palette change.
struct BaseStack: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets
    let shared: SharedObstacles

    var body: some View {
        PaletteReader(model: model) { palette in
            ZStack {
                if let projection = model.projection(size: size, insets: insets) {
                    BaseMapLayer(model: model, projection: projection, palette: palette, insets: insets, shared: shared)
                } else {
                    PureFieldLayer(palette: palette, dotGrid: true)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Animated layer: trains, trails and labels.
struct TrafficStack: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets
    let shared: SharedObstacles

    var body: some View {
        PaletteReader(model: model) { palette in
            if let projection = model.projection(size: size, insets: insets) {
                TrainLayer(model: model, projection: projection, palette: palette,
                           infoRect: model.overlayRect(size: size, insets: insets), shared: shared)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// 1 Hz layer: the info corner, or in station view the station's name and departure boards.
struct InfoStack: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets

    var body: some View {
        PaletteReader(model: model) { palette in
            if model.selectedStation != nil {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let rect = StationPanel.footprint(model, size: size, insets: insets).insetBy(dx: 12, dy: 12)
                    let k = StationPanel.scale(model, size: size, insets: insets)
                    StationPanel(model: model, palette: palette, now: model.clockOverride ?? timeline.date)
                        .scaleEffect(k, anchor: .topLeading)
                        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                        .position(x: rect.midX, y: rect.midY)
                }
                .allowsHitTesting(false)
            } else if model.settings.infoEnabled || model.center == nil {
                InfoCorner(model: model, palette: palette, size: size, insets: insets)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Base maps

struct BaseMapLayer: View {
    let model: AppModel
    let projection: Projection
    let palette: Palette
    let insets: EdgeInsets
    let shared: SharedObstacles

    var body: some View {
        let s = model.settings
        let focus = model.selectedStation.flatMap { model.rail?.stations[safe: $0]?.position }
        let rings = RingsLayer(projection: projection, palette: palette, settings: s, focus: focus)
        let network = NetworkOptions(model: model, palette: palette, size: projection.size, insets: insets)
        let lights = s.glyph == .stationLights ? model.stationLights : nil
        switch s.mapStyle {
        case .schematic:
            SchematicLayer(geo: model.geo, rail: model.rail, projection: projection, palette: palette,
                           options: network.options, drawBaseMap: true, dotGrid: s.showDotGrid, trackColor: network.trackColor,
                           shared: shared, rings: rings, agencyType: s.agencyTypography, lights: lights)
                .onDisappear { shared.rects = [] }
        case .appleMap:
            ZStack {
                AppleMapLayer(projection: projection, dark: palette.isDark)
                if s.tintAppleMap {
                    // Wash the map toward the palette so trains stay the brightest thing on screen.
                    palette.water.color.opacity(palette.isDark ? 0.42 : 0.32)
                }
                SchematicLayer(geo: nil, rail: model.rail, projection: projection, palette: palette,
                               options: network.options, drawBaseMap: false, dotGrid: false, trackColor: network.trackColor,
                               shared: shared, rings: rings, agencyType: s.agencyTypography, lights: lights)
            }
        case .pureField:
            SchematicLayer(geo: nil, rail: model.rail, projection: projection, palette: palette,
                           options: network.options, drawBaseMap: false, dotGrid: s.showDotGrid, trackColor: network.trackColor,
                           shared: shared, rings: rings, fieldFill: true, agencyType: s.agencyTypography, lights: lights)
        }
    }
}

/// What the network layer draws, derived from settings.
struct NetworkOptions {
    let options: SchematicGeometry.Options
    let trackColor: (RailLine) -> RGBA

    /// - Parameters: size, insets: when given, station names keep clear of the info corner.
    @MainActor init(model: AppModel, palette: Palette, size: CGSize? = nil, insets: EdgeInsets = EdgeInsets()) {
        let s = model.settings
        var avoid: [CGRect] = []
        if let size, let rect = model.overlayRect(size: size, insets: insets) { avoid.append(rect) }
        options = SchematicGeometry.Options(roads: s.showRoads && s.mapStyle == .schematic, track: s.showTrack,
                                            stations: s.showStations, stationNames: s.showStationNames, systems: s.systems,
                                            avoid: avoid, markRadius: s.glyph == .stationLights ? 11 : 3,
                                            stationSigns: s.stationSigns)
        let mode = s.colorMode
        trackColor = { line in
            switch mode {
            case .line: palette.lineColor(line.mapColor)
            case .system: palette.lineColor(line.system.info.color)
            case .monochrome: palette.monochrome
            }
        }
    }
}

struct PureFieldLayer: View {
    let palette: Palette
    let dotGrid: Bool

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.land.color))
            if dotGrid { DotGrid.draw(in: &ctx, size: size, color: palette.dotGrid) }
        }
    }
}

enum DotGrid {
    static let spacing: CGFloat = 22

    static func draw(in ctx: inout GraphicsContext, size: CGSize, color: RGBA) {
        var path = Path()
        let r: CGFloat = 0.85
        // Centre the grid so it is symmetric on any screen size.
        let ox = (size.width.truncatingRemainder(dividingBy: spacing)) / 2
        let oy = (size.height.truncatingRemainder(dividingBy: spacing)) / 2
        var y = oy
        while y <= size.height {
            var x = ox
            while x <= size.width {
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                x += spacing
            }
            y += spacing
        }
        ctx.fill(path, with: .color(color.color))
    }
}

/// Base map (Natural Earth) plus the rail network, projected off the main thread and cached.
struct SchematicLayer: View {
    let geo: GeoData?
    let rail: RailNetwork?
    let projection: Projection
    let palette: Palette
    let options: SchematicGeometry.Options
    /// Land, water, roads; off when another map sits underneath.
    let drawBaseMap: Bool
    let dotGrid: Bool
    let trackColor: (RailLine) -> RGBA
    var shared: SharedObstacles?
    var rings: RingsLayer?
    /// Pure Field: a flat ground fill instead of land and water.
    var fieldFill = false
    /// Station names in each agency's typeface.
    var agencyType = true
    /// Station Lights style: stations as LED pills instead of dots.
    var lights: StationLights? = nil

    @State private var built: (paths: SchematicPaths, projection: Projection)?
    @Environment(\.renderSynchronously) private var renderSynchronously

    private struct BuildKey: Hashable {
        var projection: Projection
        var options: SchematicGeometry.Options
        var hasGeo: Bool
        var hasRail: Bool
    }

    var body: some View {
        Canvas { ctx, size in
            if fieldFill {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.land.color))
            } else if drawBaseMap {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.water.color))
            }
            // ImageRenderer never runs `.task`, so headless renders build inline.
            var current = built
            if current == nil, renderSynchronously {
                let paths = SchematicGeometry.build(drawBaseMap ? geo : nil, rail: rail, projection: projection, options: options)
                shared?.rects = paths.stationLabels.map(\.rect)
                current = (paths, projection)
            }
            if dotGrid { DotGrid.draw(in: &ctx, size: size, color: palette.dotGrid.with(alpha: fieldFill ? 1 : 0.7)) }
            if let built = current {
                var map = ctx
                // While a rebuild is in flight (e.g. dragging zoom), stretch the old paths into place.
                map.concatenate(Self.transform(from: built.projection, to: projection))
                let k = projection.scale / built.projection.scale
                if drawBaseMap { drawBase(built.paths, in: &map, scale: k) }
                drawNetwork(built.paths, in: &map, scale: k)
            }
            rings?.draw(in: &ctx, size: size)
        }
        .task(id: BuildKey(projection: projection, options: options, hasGeo: geo != nil, hasRail: rail != nil)) {
            guard rail != nil || geo != nil else { return }
            if built != nil { try? await Task.sleep(for: .milliseconds(60)) }   // debounce slider drags
            guard !Task.isCancelled else { return }
            let p = projection, o = options, g = drawBaseMap ? geo : nil, r = rail
            let paths = await Task.detached(priority: .userInitiated) { SchematicGeometry.build(g, rail: r, projection: p, options: o) }.value
            guard !Task.isCancelled else { return }
            built = (paths, p)
            shared?.rects = paths.stationLabels.map(\.rect)
        }
    }

    private func drawBase(_ p: SchematicPaths, in ctx: inout GraphicsContext, scale: Double) {
        let hair = 1 / max(0.01, scale)   // keep hairlines ~constant while stretched
        ctx.fill(Path(p.land), with: .color(palette.land.color), style: FillStyle(eoFill: true))
        ctx.fill(Path(p.urban), with: .color(palette.urban.color), style: FillStyle(eoFill: true))
        ctx.fill(Path(p.lakes), with: .color(palette.water.color), style: FillStyle(eoFill: true))
        ctx.stroke(Path(p.lakes), with: .color(palette.river.color), lineWidth: 0.6 * hair)
        ctx.stroke(Path(p.land), with: .color(palette.river.color), lineWidth: 0.6 * hair)
        ctx.stroke(Path(p.rivers), with: .color(palette.river.color), style: StrokeStyle(lineWidth: 1.1 * hair, lineCap: .round, lineJoin: .round))
        ctx.stroke(Path(p.roads), with: .color(palette.road.color), style: StrokeStyle(lineWidth: 0.8 * hair, lineCap: .round, lineJoin: .round))
        ctx.stroke(Path(p.states), with: .color(palette.stateLine.color), style: StrokeStyle(lineWidth: 0.7 * hair, dash: [4 * hair, 3 * hair]))
    }

    private func drawNetwork(_ p: SchematicPaths, in ctx: inout GraphicsContext, scale: Double) {
        let hair = 1 / max(0.01, scale)
        guard let rail else { return }
        let zoom = projection.radiusNM / Geo.nmPerMile
        // Track thickens as the map zooms in: a thread across the region, a ribbon downtown.
        let metroWidth = (zoom <= 4 ? 3.2 : zoom <= 10 ? 2.4 : zoom <= 25 ? 1.7 : 1.2) * hair
        let mainWidth = metroWidth * 0.7
        for (line, path) in p.track {
            guard let l = rail.lines[safe: line] else { continue }
            let color = trackColor(l).with(alpha: palette.trackOpacity).color
            if l.system.isMainline {
                // Commuter and intercity rail: a thin double line, like a railway on a topo map.
                ctx.stroke(Path(path), with: .color(color), style: StrokeStyle(lineWidth: mainWidth * 1.9, lineCap: .round, lineJoin: .round))
                ctx.stroke(Path(path), with: .color(palette.land.with(alpha: 0.75).color),
                           style: StrokeStyle(lineWidth: mainWidth * 0.7, lineCap: .round, lineJoin: .round))
            } else {
                ctx.stroke(Path(path), with: .color(color), style: StrokeStyle(lineWidth: metroWidth, lineCap: .round, lineJoin: .round))
            }
        }

        if let lights {
            // Each station a pill of dark LEDs, waiting for trains.
            var pills = Path(), leds = Path()
            for s in p.stations {
                guard let node = lights.nodes[s.station] else { continue }
                let rot = StationPill.rotation(trackBearing: node.trackBearing)
                pills.addPath(StationPill.path(at: s.point, groups: node.groups.count, rotation: rot, scale: hair))
                for g in node.groups.indices {
                    for side in 0..<2 {
                        let c = StationPill.ledCenter(at: s.point, groups: node.groups.count, rotation: rot, group: g, side: side, scale: hair)
                        let r = StationPill.led / 2 * hair
                        leds.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    }
                }
            }
            ctx.fill(pills, with: .color(palette.land.color))
            ctx.stroke(pills, with: .color(palette.station.color), lineWidth: 1 * hair)
            ctx.fill(leds, with: .color(StationPill.unlit(palette).color))
        }
        let r = (zoom <= 10 ? 2.6 : 2.0) * hair
        var minor = Path(), major = Path()
        for s in p.stations where lights?.nodes[s.station] == nil {
            let rr = s.isMajor ? r * 1.35 : r
            let rect = CGRect(x: s.point.x - rr, y: s.point.y - rr, width: rr * 2, height: rr * 2)
            if s.isMajor { major.addEllipse(in: rect) } else { minor.addEllipse(in: rect) }
        }
        ctx.fill(minor, with: .color(palette.land.color))
        ctx.fill(major, with: .color(palette.land.color))
        ctx.stroke(minor, with: .color(palette.station.with(alpha: 0.7).color), lineWidth: 0.9 * hair)
        ctx.stroke(major, with: .color(palette.station.color), lineWidth: 1.2 * hair)

        for label in p.stationLabels where label.signFontSize > 0 {
            drawSign(label, rail: rail, in: &ctx)
        }
        for label in p.stationLabels where label.signFontSize == 0 {
            let text = Text(label.name.uppercased())
                .font(agencyType ? Signage.font(label.system, size: label.isMajor ? 9.5 : 8.5) : Typeface.station(major: label.isMajor))
                .tracking(0.6)
                .foregroundColor((label.isMajor ? palette.stationLabel : palette.stationLabel.with(alpha: 0.8)).color)
            // Anchor to the station side, so a name that runs longer than estimated grows away from its dot.
            switch label.slot {
            case .right: ctx.draw(text, at: CGPoint(x: label.rect.minX + 2, y: label.rect.midY), anchor: .leading)
            case .left: ctx.draw(text, at: CGPoint(x: label.rect.maxX - 2, y: label.rect.midY), anchor: .trailing)
            case .above, .below: ctx.draw(text, at: CGPoint(x: label.rect.midX, y: label.rect.midY), anchor: .center)
            }
        }
    }

    /// A station's name sign, drawn to its railway's standards, with a leader line when it sits away from the station.
    private func drawSign(_ label: SchematicPaths.StationLabel, rail: RailNetwork, in ctx: inout GraphicsContext) {
        let rect = label.rect
        if let from = label.leaderFrom {
            let to = CGPoint(x: min(max(from.x, rect.minX), rect.maxX), y: min(max(from.y, rect.minY), rect.maxY))
            var leader = Path()
            leader.move(to: from)
            leader.addLine(to: to)
            ctx.stroke(leader, with: .color(palette.station.with(alpha: 0.8).color), lineWidth: 0.8)
        }
        SignRenderer.draw(name: label.name, system: label.system, marks: StationSigns.marks(station: label.station, rail: rail),
                          rail: rail, fontSize: label.signFontSize, in: rect, shadow: palette.isDark ? 0.5 : 0.22, ctx: &ctx)
    }

    static func transform(from old: Projection, to new: Projection) -> CGAffineTransform {
        if old == new { return .identity }
        let k = new.scale / old.scale
        let co = Projection.world(old.center), cn = Projection.world(new.center)
        let bx = Double(new.size.width) / 2 + Double(co.x - cn.x) * new.scale - Double(old.size.width) / 2 * k
        let by = Double(new.size.height) / 2 + Double(co.y - cn.y) * new.scale - Double(old.size.height) / 2 * k
        return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: bx, ty: by)
    }
}

/// Apple's muted map, framed to exactly the same Mercator rect as everything drawn on top.
struct AppleMapLayer: NSViewRepresentable {
    static let saturation = 0.25
    let projection: Projection
    let dark: Bool

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        view.preferredConfiguration = config
        view.isZoomEnabled = false
        view.isScrollEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.showsZoomControls = false
        view.showsScale = false
        view.showsUserLocation = false
        view.showsPitchControl = false
        // Mostly desaturate Apple's palette so the map recedes like the other styles.
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        if let filter = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: Self.saturation]) {
            view.contentFilters = [filter]
        }
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        let rect = projection.mapRect
        let current = view.visibleMapRect
        if abs(current.midX - rect.midX) > 1 || abs(current.width - rect.width) / rect.width > 0.001 {
            view.setVisibleMapRect(rect, animated: false)
        }
    }
}

extension Projection {
    var mapRect: MKMapRect {
        let r = worldRect, w = MKMapSize.world.width
        return MKMapRect(x: r.minX * w, y: r.minY * w, width: r.width * w, height: r.height * w)
    }
}

// MARK: - Range rings & "you are here"

struct RingsLayer: View {
    let projection: Projection
    let palette: Palette
    let settings: WallpaperSettings
    /// Station view: mark this station instead of drawing rings around the centre.
    var focus: Coordinate? = nil

    var body: some View {
        Canvas { ctx, size in draw(in: &ctx, size: size) }
            .allowsHitTesting(false)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        if let focus {
            // A quiet target around the station: two rings and four ticks.
            let p = projection.point(focus)
            for (r, w, a) in [(18.0, 1.4, 0.8), (30.0, 0.8, 0.45)] {
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(palette.crosshair.with(alpha: a).color), lineWidth: w)
            }
            var ticks = Path()
            for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
                ticks.move(to: CGPoint(x: p.x + dx * 33, y: p.y + dy * 33))
                ticks.addLine(to: CGPoint(x: p.x + dx * 42, y: p.y + dy * 42))
            }
            ctx.stroke(ticks, with: .color(palette.crosshair.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            return
        }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        if settings.showRangeRings {
            let radii = RangeRings.radii(forZoomMiles: settings.zoomMiles)
            for (i, miles) in radii.enumerated() {
                let r = miles * Geo.nmPerMile * projection.pointsPerNM
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                let outer = i == radii.count - 1
                ctx.stroke(Path(ellipseIn: rect), with: .color(palette.ring.color),
                           style: StrokeStyle(lineWidth: outer ? 0.9 : 0.7, dash: outer ? [] : [2, 4]))
                // Label just outside the ring at the 1:30 position.
                let a = -Double.pi / 4
                let lp = CGPoint(x: c.x + (r + 4) * cos(a), y: c.y + (r + 4) * sin(a))
                let label = Text(Format.ringLabel(miles)).font(Typeface.mono(8.5, .medium)).tracking(0.8)
                    .foregroundColor(palette.ringLabel.color)
                ctx.draw(label, at: lp, anchor: .bottomLeading)
            }
        }
        // Crosshair: four short strokes around a gap, plus a centre dot.
        var cross = Path()
        for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
            cross.move(to: CGPoint(x: c.x + dx * 4, y: c.y + dy * 4))
            cross.addLine(to: CGPoint(x: c.x + dx * 10, y: c.y + dy * 10))
        }
        ctx.stroke(cross, with: .color(palette.crosshair.color), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4)), with: .color(palette.crosshair.color))
    }
}

private struct RenderSynchronouslyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set for headless snapshot renders, where async work never runs.
    var renderSynchronously: Bool {
        get { self[RenderSynchronouslyKey.self] }
        set { self[RenderSynchronouslyKey.self] = newValue }
    }
}
