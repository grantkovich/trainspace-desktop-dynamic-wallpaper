import CoreGraphics
import Foundation

/// Pre-projected base-map paths for one projection. Built off the main thread whenever the
/// location, zoom, or screen size changes; drawn from cache.
public struct SchematicPaths: @unchecked Sendable {
    public var land = CGMutablePath()
    public var lakes = CGMutablePath()
    public var urban = CGMutablePath()
    public var rivers = CGMutablePath()
    public var roads = CGMutablePath()
    public var states = CGMutablePath()
    /// Track per line, in drawing order (mainline first, metro on top).
    public var track: [(line: Int, path: CGMutablePath)] = []
    public var stations: [StationMark] = []
    public var stationLabels: [StationLabel] = []

    public struct StationMark: Sendable, Hashable {
        public var point: CGPoint
        public var isMajor: Bool
        public var system: TransitSystem
        /// Index into `RailNetwork.stations`.
        public var station: Int = -1
    }

    public struct StationLabel: Sendable, Hashable {
        public var name: String
        public var rect: CGRect
        public var isMajor: Bool
        /// Which side of the station it sits on; text is anchored to the station side of `rect`.
        public var slot: LabelSlot
        /// Whose station it is, for lettering it in that agency's typeface.
        public var system: TransitSystem = .metrorail
        /// Index into `RailNetwork.stations`.
        public var station: Int = -1
        /// Station-sign text size, when drawn as a sign.
        public var signFontSize: CGFloat = 0
        /// Where the station is, when the sign had to sit further out and needs a leader line to it.
        public var leaderFrom: CGPoint?
    }

    public init() {}
}

public enum SchematicGeometry {
    public struct Options: Hashable, Sendable {
        public var roads = true
        public var track = true
        public var stations = true
        public var stationNames = true
        public var systems: Set<TransitSystem> = Set(TransitSystem.allCases)
        /// Screen areas station names must stay out of (the info corner).
        public var avoid: [Rect] = []
        /// Half the size of a station's mark (a dot, or a pill of LEDs), so names keep clear of it.
        public var markRadius: Double = 3
        /// Label every station, as a small sign in its railway's own style (see `StationSigns`).
        public var stationSigns = false

        public init(roads: Bool = true, track: Bool = true, stations: Bool = true, stationNames: Bool = true,
                    systems: Set<TransitSystem> = Set(TransitSystem.allCases), avoid: [CGRect] = [], markRadius: Double = 3,
                    stationSigns: Bool = false) {
            self.roads = roads
            self.track = track
            self.stations = stations
            self.stationNames = stationNames
            self.systems = systems
            self.avoid = avoid.map(Rect.init)
            self.markRadius = markRadius
            self.stationSigns = stationSigns
        }
    }

    /// A hashable rectangle, so options can key the geometry cache.
    public struct Rect: Hashable, Sendable {
        public var x, y, width, height: Double
        public init(_ r: CGRect) { (x, y, width, height) = (r.minX, r.minY, r.width, r.height) }
        public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// How far out (zoom radius in miles) each station rank keeps its dot and its name.
    static let dotZoom: [Double] = [.infinity, .infinity, 16]

    /// Whether a station of this rank gets a mark at this zoom (radius in miles).
    public static func showsStation(rank: UInt8, zoomMiles: Double) -> Bool { zoomMiles <= dotZoom[min(Int(rank), 2)] }
    static let nameZoom: [Double] = [30, 10, 4.5]

    /// Approximate metrics of the station label font (9 pt expanded semibold, tracked), so
    /// placement can run off the main thread without measuring text.
    public static let stationLabelHeight: CGFloat = 12
    public static func stationLabelWidth(_ name: String, major: Bool) -> CGFloat {
        CGFloat(name.count) * (major ? 7.9 : 7.0) + 4
    }

    public static func build(_ geo: GeoData?, rail: RailNetwork?, projection p: Projection, options: Options = .init()) -> SchematicPaths {
        var out = SchematicPaths()
        let view = CGRect(origin: .zero, size: p.size)
        let near = view.insetBy(dx: -64, dy: -64)
        let bounds = p.visibleBounds.expanded(by: 0.08)
        let radius = p.radiusNM

        if let geo {
            func add(_ layer: GeoLayer, to path: CGMutablePath, closed: Bool, maxRank: UInt8 = .max) {
                for feature in geo.features(layer, in: bounds) where feature.rank <= maxRank {
                    for ring in feature.rings {
                        appendLine(ring, projection: p, near: near, closed: closed, to: path)
                    }
                }
            }
            add(.land, to: out.land, closed: true)
            add(.lakes, to: out.lakes, closed: true)
            add(.urban, to: out.urban, closed: true)
            add(.rivers, to: out.rivers, closed: false)
            add(.states, to: out.states, closed: false)
            if options.roads {
                add(.roads, to: out.roads, closed: false, maxRank: radius < 15 ? .max : (radius < 35 ? 8 : 6))
            }
        }

        guard let rail else { return out }
        if options.track {
            var byLine: [Int: CGMutablePath] = [:]
            for shape in rail.shapes {
                let system = rail.lines[shape.line].system
                guard options.systems.contains(system),
                      shape.bounds.intersects(bounds) else { continue }
                let path = byLine[shape.line] ?? CGMutablePath()
                appendLine(shape.points, projection: p, near: near, closed: false, to: path)
                byLine[shape.line] = path
            }
            out.track = byLine.sorted { drawOrder($0.key, rail) < drawOrder($1.key, rail) }
                .map { ($0.key, $0.value) }
        }

        if options.stations {
            let zoomMiles = radius / Geo.nmPerMile
            var requests: [LabelRequest] = []
            var names: [String: (String, Bool, TransitSystem, Int)] = [:]   // name, major, system, station
            let signSize = CGFloat(StationSigns.fontSize(zoomMiles: zoomMiles))
            for (i, s) in rail.stations.enumerated() where options.systems.contains(s.system) && bounds.contains(s.position) {
                // Minor stations crowd wide views; show them once the map is zoomed in (signs: always).
                let rank = min(Int(s.rank), 2)
                guard options.stationSigns || zoomMiles <= dotZoom[rank] else { continue }
                let pt = p.point(s.position)
                guard near.contains(pt) else { continue }
                let major = rank < 2
                out.stations.append(.init(point: pt, isMajor: major, system: s.system, station: i))
                guard options.stationNames, view.insetBy(dx: 20, dy: 20).contains(pt),
                      options.stationSigns || zoomMiles <= nameZoom[rank] else { continue }
                let id = "s\(i)"
                let shown = options.stationSigns ? StationSigns.displayName(station: i, rail: rail) : s.name
                names[id] = (shown, major, s.system, i)
                let size = options.stationSigns
                    ? StationSigns.size(name: shown, system: s.system, marks: StationSigns.marks(station: i, rail: rail),
                                        rail: rail, fontSize: signSize)
                    : CGSize(width: stationLabelWidth(s.name, major: major), height: stationLabelHeight)
                requests.append(LabelRequest(id: id, anchor: pt, size: size,
                                             priority: Double(rank) * 10_000 + Double(hypot(pt.x - view.midX, pt.y - view.midY)),
                                             gap: CGFloat(options.markRadius) + 3))
            }
            let labelBounds = view.insetBy(dx: 8, dy: 8)
            let placed = LabelLayout.layout(requests, obstacles: options.avoid.map(\.cgRect), bounds: labelBounds,
                                            previous: [:], glyphRadius: CGFloat(options.markRadius))
            out.stationLabels = placed.compactMap { l in
                names[l.id].map { SchematicPaths.StationLabel(name: $0.0, rect: l.rect, isMajor: $0.1, slot: l.slot, system: $0.2,
                                                              station: $0.3, signFontSize: options.stationSigns ? signSize : 0) }
            }
            if options.stationSigns {
                // Every station gets its sign: ones with no room beside the station move further out on a leader line.
                let marks = out.stations.map { CGRect(x: $0.point.x - options.markRadius, y: $0.point.y - options.markRadius,
                                                      width: options.markRadius * 2, height: options.markRadius * 2) }
                var taken = out.stationLabels.map(\.rect) + options.avoid.map(\.cgRect)
                let placedIDs = Set(placed.map(\.id))
                for req in requests.sorted(by: { $0.priority < $1.priority }) where !placedIDs.contains(req.id) {
                    guard let info = names[req.id],
                          let rect = Self.leaderSpot(for: req, taken: taken, marks: marks, bounds: labelBounds) else { continue }
                    taken.append(rect)
                    out.stationLabels.append(SchematicPaths.StationLabel(name: info.0, rect: rect, isMajor: info.1, slot: .right,
                                                                         system: info.2, station: info.3, signFontSize: signSize,
                                                                         leaderFrom: req.anchor))
                }
            }
        }
        return out
    }

    /// The nearest free spot for a sign, searching outward in eight directions.
    static func leaderSpot(for req: LabelRequest, taken: [CGRect], marks: [CGRect], bounds: CGRect) -> CGRect? {
        let w = req.size.width, h = req.size.height
        for distance in stride(from: 26.0, through: 140, by: 14) {
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4 + (k % 2 == 0 ? 0 : 0.1)
                let cx = req.anchor.x + CGFloat(cos(angle) * distance), cy = req.anchor.y + CGFloat(sin(angle) * distance)
                // Sit the sign beyond the point, on the side facing away from the station.
                let x = cos(angle) >= 0 ? cx : cx - w
                let r = CGRect(x: x, y: cy - h / 2, width: w, height: h)
                guard bounds.contains(r), !taken.contains(where: { $0.intersects(r) }),
                      !marks.contains(where: { $0.intersects(r) }) else { continue }
                return r
            }
        }
        return nil
    }

    /// Mainline under light rail under metro; within a system, the order the network lists its
    /// lines (busiest trunk lines last, so on top).
    static func drawOrder(_ line: Int, _ rail: RailNetwork) -> Int {
        let kind = switch rail.lines[line].system.kind {
        case .intercity: 0
        case .commuter: 1
        case .lightRail: 2
        case .rapidTransit: 3
        }
        return kind << 20 | line
    }

    /// Projects one polyline with screen-space thinning: fine (0.6 pt) near the view, coarse far away.
    /// Coarse tolerance stays below the margin, so thinned edges can never cut into the view.
    static func appendLine(_ ring: [GeoPoint], projection p: Projection, near: CGRect, closed: Bool, to path: CGMutablePath) {
        guard ring.count >= 2 else { return }
        var last = CGPoint.zero
        var emitted = 0
        for (i, g) in ring.enumerated() {
            let pt = p.point(Coordinate(g))
            if emitted > 0 && i != ring.count - 1 {
                let tol: CGFloat = near.contains(pt) || near.contains(last) ? 0.6 : 24
                if abs(pt.x - last.x) < tol && abs(pt.y - last.y) < tol { continue }
            }
            if emitted == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            last = pt
            emitted += 1
        }
        if closed { path.closeSubpath() }
    }
}

public enum RangeRings {
    /// Up to three "nice" ring radii (in miles) that fit inside the zoom radius.
    public static func radii(forZoomMiles zoom: Double) -> [Double] {
        let nice: [Double] = [0.5, 1, 2, 2.5, 5, 10, 15, 20, 25, 50]
        let outer = nice.last { $0 <= zoom * 0.92 } ?? nice[0]
        var rings = [outer]
        for fraction in [0.5, 0.25] {
            let target = outer * fraction
            if let r = nice.last(where: { $0 <= target * 1.05 }), r < rings.last!, r >= outer * 0.18 {
                rings.append(r)
            }
        }
        return rings.reversed()
    }
}
