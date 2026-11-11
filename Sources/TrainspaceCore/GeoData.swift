import Foundation

public enum GeoLayer: UInt8, CaseIterable, Sendable { case land = 0, lakes, rivers, urban, roads, states }

/// A compact lat/lon pair (Float precision ≈ 1 m, plenty at wallpaper scale).
public typealias GeoPoint = SIMD2<Float>   // (lat, lon)

public struct GeoFeature: Sendable {
    public var rank: UInt8
    public var bounds: GeoBounds
    public var rings: [[GeoPoint]]
}

public enum GeoDataError: Error { case badMagic, unsupportedVersion(UInt8), decompressionFailed, truncated, invalid }

/// Bundled base-map geometry (Natural Earth 10m, clipped to the region). See Tools/build_geodata.py.
public final class GeoData: Sendable {
    public let layers: [GeoLayer: [GeoFeature]]

    init(layers: [GeoLayer: [GeoFeature]]) {
        self.layers = layers
    }

    public static func load(from url: URL) throws -> GeoData {
        try decode(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func features(_ layer: GeoLayer, in bounds: GeoBounds) -> [GeoFeature] {
        (layers[layer] ?? []).filter { $0.bounds.intersects(bounds) }
    }

    public static func decode(_ file: Data) throws -> GeoData {
        try BinaryFile.inflate(file, magic: "TSGD", version: 1) { r in
            var layers: [GeoLayer: [GeoFeature]] = [:]
            let layerCount = try r.u8()
            for _ in 0..<layerCount {
                let id = try r.u8()
                let count = Int(try r.u32())
                var features: [GeoFeature] = []
                features.reserveCapacity(count)
                for _ in 0..<count {
                    let rank = try r.u8()
                    let ringCount = Int(try r.u16())
                    var rings: [[GeoPoint]] = []
                    rings.reserveCapacity(ringCount)
                    for _ in 0..<ringCount {
                        rings.append(try r.polyline(count: Int(try r.varint())))
                    }
                    features.append(GeoFeature(rank: rank, bounds: GeoBounds(enclosing: rings), rings: rings))
                }
                if let layer = GeoLayer(rawValue: id) { layers[layer] = features }
            }
            return GeoData(layers: layers)
        }
    }
}

extension GeoBounds {
    init(enclosing rings: [[GeoPoint]]) {
        var minLat = Float.infinity, maxLat = -Float.infinity, minLon = Float.infinity, maxLon = -Float.infinity
        for ring in rings {
            for p in ring {
                minLat = min(minLat, p.x); maxLat = max(maxLat, p.x)
                minLon = min(minLon, p.y); maxLon = max(maxLon, p.y)
            }
        }
        self.init(minLat: Double(minLat), maxLat: Double(maxLat), minLon: Double(minLon), maxLon: Double(maxLon))
    }
}

/// Shared framing for the bundled files: 4-byte magic, version byte, raw-deflate payload.
enum BinaryFile {
    static func inflate<T>(_ file: Data, magic: String, version: UInt8, _ body: (inout BinaryReader) throws -> T) throws -> T {
        guard file.count > 5, file.prefix(4) == Data(magic.utf8) else { throw GeoDataError.badMagic }
        let v = file[file.startIndex + 4]
        guard v == version else { throw GeoDataError.unsupportedVersion(v) }
        guard let raw = try? (Data(file.dropFirst(5)) as NSData).decompressed(using: .zlib) as Data else {
            throw GeoDataError.decompressionFailed
        }
        return try raw.withUnsafeBytes { buf in
            var r = BinaryReader(buf: buf)
            return try body(&r)
        }
    }
}

struct BinaryReader {
    let buf: UnsafeRawBufferPointer
    var i = 0

    mutating func u8() throws -> UInt8 {
        guard i < buf.count else { throw GeoDataError.truncated }
        defer { i += 1 }
        return buf[i]
    }

    mutating func bytes(_ n: Int) throws -> UnsafeRawBufferPointer {
        guard n >= 0, i + n <= buf.count else { throw GeoDataError.truncated }
        defer { i += n }
        return UnsafeRawBufferPointer(rebasing: buf[i..<(i + n)])
    }

    mutating func u16() throws -> UInt16 { try bytes(2).loadUnaligned(as: UInt16.self).littleEndian }
    mutating func u24() throws -> UInt32 {
        let b = try bytes(3)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
    }
    mutating func u32() throws -> UInt32 { try bytes(4).loadUnaligned(as: UInt32.self).littleEndian }
    mutating func i32() throws -> Int32 { try bytes(4).loadUnaligned(as: Int32.self).littleEndian }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try u8()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw GeoDataError.truncated }
        }
    }

    mutating func int() throws -> Int {
        let v = try varint()
        guard v <= UInt64(Int.max) else { throw GeoDataError.invalid }
        return Int(v)
    }

    mutating func zigzag() throws -> Int64 {
        let n = try varint()
        return Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
    }

    mutating func string() throws -> String {
        let n = try int()
        return String(decoding: try bytes(n), as: UTF8.self)
    }

    /// Delta-encoded (lat, lon) pairs in 1e-5 degrees.
    mutating func polyline(count n: Int) throws -> [GeoPoint] {
        var out = [GeoPoint]()
        out.reserveCapacity(n)
        var lat: Int64 = 0, lon: Int64 = 0
        for _ in 0..<n {
            lat += try zigzag()
            lon += try zigzag()
            out.append(GeoPoint(Float(lat) / 100_000, Float(lon) / 100_000))
        }
        return out
    }
}
