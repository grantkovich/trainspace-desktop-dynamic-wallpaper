import Foundation

/// Spatial index over every track segment, for keeping trains on the rails: snapping a
/// reported position to the nearest track, and moving a train along the track rather than in
/// a straight line between reports.
public final class TrackIndex: Sendable {
    public struct Hit: Sendable, Equatable {
        public var shape: Int
        /// Segment index: between points `segment` and `segment + 1`.
        public var segment: Int
        /// 0…1 along the segment.
        public var t: Double
        public var coordinate: Coordinate
        /// Heading of the track at this point, in the shape's own direction.
        public var trackBearing: Double
        public var distanceMeters: Double
    }

    private struct SegmentRef: Sendable {
        var shape: Int32
        var segment: Int32
    }

    private let network: RailNetwork
    /// Points per shape in local metres, so queries don't convert each time.
    private let xy: [[SIMD2<Double>]]
    private let grid: [Int64: [SegmentRef]]
    static let cell = 500.0   // metres

    public init(network: RailNetwork) {
        self.network = network
        let metric = network.metric
        let xy = network.shapes.map { $0.points.map(metric.xy) }
        var grid: [Int64: [SegmentRef]] = [:]
        for (s, pts) in xy.enumerated() where pts.count >= 2 {
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let (x0, y0) = Self.cellOf(SIMD2(min(a.x, b.x), min(a.y, b.y)))
                let (x1, y1) = Self.cellOf(SIMD2(max(a.x, b.x), max(a.y, b.y)))
                for cx in x0...x1 {
                    for cy in y0...y1 {
                        grid[Self.key(cx, cy), default: []].append(SegmentRef(shape: Int32(s), segment: Int32(i)))
                    }
                }
            }
        }
        self.xy = xy
        self.grid = grid
    }

    private static func cellOf(_ p: SIMD2<Double>) -> (Int, Int) {
        (Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))
    }

    private static func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }

    /// Nearest track within `maxMeters`, optionally only on one system's or one line's track.
    /// A bearing, when given, breaks ties between parallel tracks in favour of the one heading
    /// the same way (either direction counts: trains run both ways on most track).
    public func nearest(_ c: Coordinate, system: TransitSystem? = nil, line: Int? = nil,
                        bearing: Double? = nil, maxMeters: Double = 300) -> Hit? {
        let p = network.metric.xy(c)
        let (cx, cy) = Self.cellOf(p)
        let reach = Int((maxMeters / Self.cell).rounded(.up))
        var best: (score: Double, ref: SegmentRef, t: Double, d: Double)?
        for dx in -reach...reach {
            for dy in -reach...reach {
                guard let refs = grid[Self.key(cx + dx, cy + dy)] else { continue }
                for ref in refs {
                    let shape = network.shapes[Int(ref.shape)]
                    if let line, shape.line != line { continue }
                    if let system, network.lines[shape.line].system != system { continue }
                    let pts = xy[Int(ref.shape)]
                    let a = pts[Int(ref.segment)], b = pts[Int(ref.segment) + 1]
                    let ab = b - a
                    let len2 = (ab * ab).sum()
                    let t = len2 > 0 ? min(1, max(0, ((p - a) * ab).sum() / len2)) : 0
                    let q = a + ab * t
                    let d = ((p - q) * (p - q)).sum().squareRoot()
                    guard d <= maxMeters else { continue }
                    var score = d
                    if let bearing, len2 > 0 {
                        // Up to 40 m penalty for a track at right angles to the train's heading.
                        let seg = atan2(ab.x, ab.y) * 180 / .pi
                        score += 40 * abs(sin((seg - bearing) * .pi / 180))
                    }
                    if best == nil || score < best!.score { best = (score, ref, t, d) }
                }
            }
        }
        guard let best else { return nil }
        return hit(shape: Int(best.ref.shape), segment: Int(best.ref.segment), t: best.t, distance: best.d)
    }

    private func hit(shape: Int, segment: Int, t: Double, distance: Double) -> Hit {
        let pts = xy[shape]
        let a = pts[segment], b = pts[segment + 1]
        let q = a + (b - a) * t
        let d = b - a
        var bearing = atan2(d.x, d.y) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return Hit(shape: shape, segment: segment, t: t, coordinate: network.metric.coordinate(q), trackBearing: bearing,
                   distanceMeters: distance)
    }

    /// Moves `meters` along the track from `hit`, in whichever direction along the shape best
    /// matches `bearing`. Stops at the end of the track. Returns the new point and the direction
    /// of travel there.
    public func advance(from hit: Hit, bearing: Double, meters: Double) -> (Coordinate, bearing: Double) {
        let forward = cos((hit.trackBearing - bearing) * .pi / 180) >= 0
        let pts = xy[hit.shape]
        var seg = hit.segment
        var pos = pts[seg] + (pts[seg + 1] - pts[seg]) * hit.t
        var remaining = max(0, meters)
        while true {
            let target = forward ? pts[seg + 1] : pts[seg]
            let gap = target - pos
            let len = (gap * gap).sum().squareRoot()
            if remaining <= len || !(forward ? seg + 1 < pts.count - 1 : seg > 0) {
                if len > 0 { pos += gap * min(1, remaining / len) }
                break
            }
            remaining -= len
            pos = target
            seg += forward ? 1 : -1
        }
        let d = pts[seg + 1] - pts[seg]
        var heading = atan2(d.x, d.y) * 180 / .pi
        if !forward { heading += 180 }
        heading = heading.truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        return (network.metric.coordinate(pos), heading)
    }
}
