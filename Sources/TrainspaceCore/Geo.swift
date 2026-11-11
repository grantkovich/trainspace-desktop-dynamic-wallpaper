import Foundation

/// A WGS84 position in degrees.
public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public enum Geo {
    public static let earthRadiusNM = 3440.065
    public static let nmPerMile = 0.868976
    public static let metersPerNM = 1852.0

    /// Great-circle distance in nautical miles.
    public static func distanceNM(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dφ = (b.latitude - a.latitude).radians
        let dλ = (b.longitude - a.longitude).radians
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadiusNM * asin(min(1, sqrt(h)))
    }

    /// Point reached by travelling `distanceNM` on initial bearing `bearingDeg`.
    /// Uses a local flat-earth step, which is exact enough for the distance a train covers between fixes.
    public static func offset(_ c: Coordinate, distanceNM: Double, bearingDeg: Double) -> Coordinate {
        let b = bearingDeg.radians
        let dLat = distanceNM * cos(b) / 60.0
        let cosLat = max(0.01, cos(c.latitude.radians))
        let dLon = distanceNM * sin(b) / (60.0 * cosLat)
        var lon = c.longitude + dLon
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return Coordinate(latitude: min(90, max(-90, c.latitude + dLat)), longitude: lon)
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north.
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dλ = (b.longitude - a.longitude).radians
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let deg = atan2(y, x).degrees
        return deg < 0 ? deg + 360 : deg
    }
}

extension Double {
    @inlinable var radians: Double { self * .pi / 180 }
    @inlinable var degrees: Double { self * 180 / .pi }
}
