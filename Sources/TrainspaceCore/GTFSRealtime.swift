import Foundation

public enum ProtobufError: Error, Equatable { case truncated, badWireType(Int) }

/// Minimal protobuf wire-format reader: enough for GTFS-Realtime vehicle positions without
/// pulling in a protobuf library.
struct ProtoReader {
    private let data: [UInt8]
    private var i: Int
    private let end: Int

    init(_ data: [UInt8], range: Range<Int>? = nil) {
        self.data = data
        self.i = range?.lowerBound ?? 0
        self.end = range?.upperBound ?? data.count
    }

    var atEnd: Bool { i >= end }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < end else { throw ProtobufError.truncated }
            let b = data[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw ProtobufError.truncated }
        }
    }

    /// (field number, wire type)
    mutating func tag() throws -> (Int, Int) {
        let t = try varint()
        return (Int(t >> 3), Int(t & 7))
    }

    mutating func fixed32() throws -> UInt32 {
        guard i + 4 <= end else { throw ProtobufError.truncated }
        defer { i += 4 }
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    mutating func fixed64() throws -> UInt64 {
        let lo = UInt64(try fixed32()), hi = UInt64(try fixed32())
        return lo | hi << 32
    }

    mutating func float() throws -> Float { Float(bitPattern: try fixed32()) }
    mutating func double() throws -> Double { Double(bitPattern: try fixed64()) }

    /// A length-delimited field's byte range, as a reader over just that range.
    mutating func message() throws -> ProtoReader {
        let n = Int(try varint())
        guard n >= 0, i + n <= end else { throw ProtobufError.truncated }
        defer { i += n }
        return ProtoReader(data, range: i..<(i + n))
    }

    mutating func string() throws -> String {
        let n = Int(try varint())
        guard n >= 0, i + n <= end else { throw ProtobufError.truncated }
        defer { i += n }
        return String(decoding: data[i..<(i + n)], as: UTF8.self)
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: guard i + 8 <= end else { throw ProtobufError.truncated }; i += 8
        case 2: let n = Int(try varint()); guard n >= 0, i + n <= end else { throw ProtobufError.truncated }; i += n
        case 5: guard i + 4 <= end else { throw ProtobufError.truncated }; i += 4
        default: throw ProtobufError.badWireType(wireType)
        }
    }
}

/// GTFS-Realtime `VehiclePosition`, flattened to what the wallpaper uses.
public struct VehiclePosition: Hashable, Sendable {
    public var hasPosition: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && (latitude != 0 || longitude != 0)
    }

    public var entityID: String
    public var tripID: String?
    public var routeID: String?
    public var directionID: Int?
    public var vehicleID: String?
    public var vehicleLabel: String?
    public var latitude: Double
    public var longitude: Double
    public var bearing: Double?
    /// Metres per second.
    public var speed: Double?
    /// 0 incoming at, 1 stopped at, 2 in transit to.
    public var currentStatus: Int?
    public var stopID: String?
    /// POSIX seconds.
    public var timestamp: TimeInterval?
}

/// GTFS-Realtime `TripUpdate`: how late a trip is running, stop by stop, or that it's cancelled.
public struct TripUpdate: Hashable, Sendable {
    public struct StopUpdate: Hashable, Sendable {
        public var stopSequence: Int?
        public var stopID: String?
        /// Seconds late (negative = early).
        public var arrivalDelay: Int?
        public var departureDelay: Int?
        /// POSIX seconds.
        public var arrivalTime: TimeInterval?
        public var departureTime: TimeInterval?
        public var skipped = false
    }
    public var tripID: String?
    public var routeID: String?
    /// yyyymmdd
    public var startDate: String?
    public var canceled = false
    /// Trip-level delay, when the feed gives one.
    public var delay: Int?
    public var stops: [StopUpdate] = []
}

/// Decodes `FeedMessage` protobufs: vehicle positions and trip updates.
public enum GTFSRealtime {
    public struct Feed: Sendable {
        public var timestamp: TimeInterval?
        public var vehicles: [VehiclePosition]
        public var tripUpdates: [TripUpdate] = []
        /// Vehicles reported without a usable position (New York's subway reports none; Metro-North
        /// most): their trip and stop, for placing them from the timetable and trip updates.
        public var unplaced: [VehiclePosition] = []
    }

    public static func decode(_ data: Data) throws -> Feed {
        var r = ProtoReader([UInt8](data))
        var feed = Feed(timestamp: nil, vehicles: [])
        while !r.atEnd {
            let (field, wire) = try r.tag()
            switch (field, wire) {
            case (1, 2):   // header
                var h = try r.message()
                while !h.atEnd {
                    let (f, w) = try h.tag()
                    if f == 3, w == 0 { feed.timestamp = TimeInterval(try h.varint()) } else { try h.skip(wireType: w) }
                }
            case (2, 2):   // entity
                var e = try r.message()
                let (v, u) = try entity(&e)
                if let v {
                    if v.hasPosition { feed.vehicles.append(v) } else { feed.unplaced.append(v) }
                }
                if let u { feed.tripUpdates.append(u) }
            default:
                try r.skip(wireType: wire)
            }
        }
        return feed
    }

    private static func entity(_ r: inout ProtoReader) throws -> (VehiclePosition?, TripUpdate?) {
        var id = ""
        var vehicle: VehiclePosition?
        var update: TripUpdate?
        var deleted = false
        while !r.atEnd {
            let (field, wire) = try r.tag()
            switch (field, wire) {
            case (1, 2): id = try r.string()
            case (2, 0): deleted = try r.varint() != 0
            case (3, 2):
                var m = try r.message()
                update = try tripUpdate(&m)
            case (4, 2):
                var m = try r.message()
                vehicle = try vehiclePosition(&m)
            default: try r.skip(wireType: wire)
            }
        }
        guard !deleted else { return (nil, nil) }
        vehicle?.entityID = id
        return (vehicle, update)
    }

    /// int32 fields are sign-extended to 64 bits on the wire.
    private static func int32(_ v: UInt64) -> Int { Int(Int64(bitPattern: v)) }

    private static func tripUpdate(_ r: inout ProtoReader) throws -> TripUpdate {
        var u = TripUpdate()
        while !r.atEnd {
            let (field, wire) = try r.tag()
            switch (field, wire) {
            case (1, 2):   // TripDescriptor
                var t = try r.message()
                while !t.atEnd {
                    let (f, w) = try t.tag()
                    switch (f, w) {
                    case (1, 2): u.tripID = try t.string()
                    case (3, 2): u.startDate = try t.string()
                    case (4, 0): u.canceled = [3, 7].contains(try t.varint())   // CANCELED, DELETED
                    case (5, 2): u.routeID = try t.string()
                    default: try t.skip(wireType: w)
                    }
                }
            case (2, 2):   // StopTimeUpdate
                var m = try r.message()
                var s = TripUpdate.StopUpdate()
                while !m.atEnd {
                    let (f, w) = try m.tag()
                    switch (f, w) {
                    case (1, 0): s.stopSequence = Int(try m.varint())
                    case (4, 2): s.stopID = try m.string()
                    case (5, 0): s.skipped = try m.varint() == 1
                    case (2, 2), (3, 2):
                        var e = try m.message()
                        var delay: Int?, time: TimeInterval?
                        while !e.atEnd {
                            let (ef, ew) = try e.tag()
                            switch (ef, ew) {
                            case (1, 0): delay = int32(try e.varint())
                            case (2, 0): time = TimeInterval(Int64(bitPattern: try e.varint()))
                            default: try e.skip(wireType: ew)
                            }
                        }
                        if f == 2 { s.arrivalDelay = delay; s.arrivalTime = time } else { s.departureDelay = delay; s.departureTime = time }
                    default: try m.skip(wireType: w)
                    }
                }
                u.stops.append(s)
            case (5, 0): u.delay = int32(try r.varint())
            default: try r.skip(wireType: wire)
            }
        }
        return u
    }

    private static func vehiclePosition(_ r: inout ProtoReader) throws -> VehiclePosition? {
        var v = VehiclePosition(entityID: "", latitude: .nan, longitude: .nan)
        while !r.atEnd {
            let (field, wire) = try r.tag()
            switch (field, wire) {
            case (1, 2):   // TripDescriptor
                var t = try r.message()
                while !t.atEnd {
                    let (f, w) = try t.tag()
                    switch (f, w) {
                    case (1, 2): v.tripID = try t.string()
                    case (5, 2): v.routeID = try t.string()
                    case (6, 0): v.directionID = Int(try t.varint())
                    default: try t.skip(wireType: w)
                    }
                }
            case (2, 2):   // Position
                var p = try r.message()
                while !p.atEnd {
                    let (f, w) = try p.tag()
                    switch (f, w) {
                    case (1, 5): v.latitude = Double(try p.float())
                    case (2, 5): v.longitude = Double(try p.float())
                    case (3, 5): v.bearing = Double(try p.float())
                    case (5, 5): v.speed = Double(try p.float())
                    default: try p.skip(wireType: w)
                    }
                }
            case (4, 0): v.currentStatus = Int(try r.varint())
            case (5, 0): v.timestamp = TimeInterval(try r.varint())
            case (7, 2): v.stopID = try r.string()
            case (8, 2):   // VehicleDescriptor
                var d = try r.message()
                while !d.atEnd {
                    let (f, w) = try d.tag()
                    switch (f, w) {
                    case (1, 2): v.vehicleID = try d.string()
                    case (2, 2): v.vehicleLabel = try d.string()
                    default: try d.skip(wireType: w)
                    }
                }
            default: try r.skip(wireType: wire)
            }
        }
        return v
    }
}
