import CoreGraphics
import Foundation

public struct GeoBounds: Hashable, Sendable {
    public var minLat, maxLat, minLon, maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat; self.maxLat = maxLat; self.minLon = minLon; self.maxLon = maxLon
    }

    public func contains(_ c: Coordinate) -> Bool {
        (minLat...maxLat).contains(c.latitude) && (minLon...maxLon).contains(c.longitude)
    }

    public func intersects(_ o: GeoBounds) -> Bool {
        minLat <= o.maxLat && o.minLat <= maxLat && minLon <= o.maxLon && o.minLon <= maxLon
    }

    public func expanded(by fraction: Double) -> GeoBounds {
        let dLat = (maxLat - minLat) * fraction, dLon = (maxLon - minLon) * fraction
        return GeoBounds(minLat: minLat - dLat, maxLat: maxLat + dLat, minLon: minLon - dLon, maxLon: maxLon + dLon)
    }
}

/// Web Mercator projection centred on a point, scaled so `radiusNM` reaches the shorter screen half-axis.
/// Screen space is top-left origin, y down, in points.
public struct Projection: Hashable, Sendable {
    public var center: Coordinate
    public var size: CGSize
    public var radiusNM: Double

    /// Points per Mercator world unit (the world is 1 × 1).
    public let scale: Double
    private let centerWorld: CGPoint

    public init(center: Coordinate, size: CGSize, radiusNM: Double) {
        self.center = center
        self.size = size
        self.radiusNM = max(0.01, radiusNM)
        let circumferenceNM = 2 * .pi * Geo.earthRadiusNM * cos(center.latitude.radians)
        let radiusWorld = self.radiusNM / circumferenceNM
        let halfShort = Double(min(size.width, size.height)) / 2
        self.scale = halfShort / radiusWorld
        self.centerWorld = Projection.world(center)
    }

    public static func world(_ c: Coordinate) -> CGPoint {
        let lat = min(85.05112878, max(-85.05112878, c.latitude)).radians
        let x = (c.longitude + 180) / 360
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2
        return CGPoint(x: x, y: y)
    }

    public static func coordinate(world p: CGPoint) -> Coordinate {
        let lon = Double(p.x) * 360 - 180
        let n = Double.pi * (1 - 2 * Double(p.y))
        let lat = atan(sinh(n)).degrees
        return Coordinate(latitude: lat, longitude: lon)
    }

    @inlinable public func point(_ c: Coordinate) -> CGPoint {
        point(world: Projection.world(c))
    }

    public func point(world w: CGPoint) -> CGPoint {
        var dx = Double(w.x - centerWorld.x)
        if dx > 0.5 { dx -= 1 } else if dx < -0.5 { dx += 1 }   // shortest way round the antimeridian
        return CGPoint(x: Double(size.width) / 2 + dx * scale,
                       y: Double(size.height) / 2 + Double(w.y - centerWorld.y) * scale)
    }

    public func coordinate(_ p: CGPoint) -> Coordinate {
        let wx = Double(centerWorld.x) + (Double(p.x) - Double(size.width) / 2) / scale
        let wy = Double(centerWorld.y) + (Double(p.y) - Double(size.height) / 2) / scale
        return Projection.coordinate(world: CGPoint(x: wx.truncatingRemainder(dividingBy: 1), y: wy))
    }

    /// The visible region in world units (origin top-left), for aligning MapKit's `MKMapRect`.
    public var worldRect: CGRect {
        let w = Double(size.width) / scale, h = Double(size.height) / scale
        return CGRect(x: Double(centerWorld.x) - w / 2, y: Double(centerWorld.y) - h / 2, width: w, height: h)
    }

    public var visibleBounds: GeoBounds {
        let tl = coordinate(CGPoint(x: 0, y: 0))
        let br = coordinate(CGPoint(x: size.width, y: size.height))
        return GeoBounds(minLat: br.latitude, maxLat: tl.latitude, minLon: tl.longitude, maxLon: br.longitude)
    }

    /// Screen points per nautical mile at the centre.
    public var pointsPerNM: Double { Double(min(size.width, size.height)) / 2 / radiusNM }
}
