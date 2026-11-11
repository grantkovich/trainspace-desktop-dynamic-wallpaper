import Foundation

public struct RailLine: Hashable, Sendable {
    /// Stable id, e.g. "metrorail.red", "marc.penn".
    public var id: String
    public var system: TransitSystem
    public var name: String
    /// Short code for labels: "RD", "PENN", "A".
    public var shortName: String
    /// The agency's colour for the line, and the text colour it uses on it (route bullets, discs).
    public var color: UInt32
    public var textColor: UInt32
    /// What the map draws, before `Palette.lineColor` tunes it for light or dark. Usually `color`;
    /// different where the agency's own would be confused with a neighbour's.
    public var mapColor: UInt32
    /// GTFS route_ids this line covers, for matching live feeds.
    public var routeIDs: [String]

    public init(id: String, system: TransitSystem, name: String, shortName: String, color: UInt32,
                textColor: UInt32 = 0xFFFFFF, mapColor: UInt32? = nil, routeIDs: [String]) {
        self.id = id
        self.system = system
        self.name = name
        self.shortName = shortName
        self.color = color
        self.textColor = textColor
        self.mapColor = mapColor ?? color
        self.routeIDs = routeIDs
    }
}

/// One track geometry (a GTFS shape), simplified, with cumulative distance along it.
public struct RailShape: Sendable {
    public var line: Int
    public var points: [GeoPoint]
    /// Metres from the first point, one per point.
    public var distances: [Float]
    public var bounds: GeoBounds
    public var length: Double { Double(distances.last ?? 0) }

    let metric: LocalMetric

    init(line: Int, points: [GeoPoint], metric: LocalMetric = .dc) {
        self.line = line
        self.points = points
        self.metric = metric
        self.bounds = GeoBounds(enclosing: [points])
        var d: [Float] = [0]
        d.reserveCapacity(points.count)
        for i in 1..<max(1, points.count) {
            d.append(d[i - 1] + Float(metric.distance(points[i - 1], points[i])))
        }
        self.distances = d
    }

    /// Position and heading at `meters` along the shape (clamped to its ends).
    public func point(atDistance meters: Double) -> (Coordinate, bearing: Double) {
        guard points.count >= 2 else {
            return (points.first.map { Coordinate($0) } ?? Coordinate(latitude: 0, longitude: 0), 0)
        }
        let m = Float(min(max(0, meters), length))
        // Binary search for the segment containing m.
        var lo = 0, hi = distances.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= m { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = distances[hi] - distances[lo]
        let t = span > 0 ? Double((m - distances[lo]) / span) : 0
        let c = Coordinate(latitude: Double(a.x) + Double(b.x - a.x) * t, longitude: Double(a.y) + Double(b.y - a.y) * t)
        return (c, metric.bearing(a, b))
    }
}

public struct Station: Hashable, Sendable {
    public var system: TransitSystem
    public var name: String
    public var position: Coordinate
    /// 0 = hub or terminal, 1 = transfer between lines, 2 = everything else. Lower ranks are
    /// labelled first and stay visible further out.
    public var rank: UInt8
    /// Amtrak's station code ("WAS", "BAL"), when Amtrak stops here.
    public var code: String = ""
    /// Stable identity for settings: system and name, plus "#2", "#3"… for the second and later
    /// stations of one system sharing a name (New York has several "86 St"). Set by `RailNetwork`.
    public internal(set) var key: String = ""

    public init(system: TransitSystem, name: String, position: Coordinate, rank: UInt8, code: String = "") {
        self.system = system
        self.name = name
        self.position = position
        self.rank = rank
        self.code = code
        self.key = "\(system.rawValue):\(name)"
    }
}

/// When a timetable runs: GTFS calendar + calendar_dates.
public struct ServiceCalendar: Hashable, Sendable {
    public var system: TransitSystem
    /// Bit 0 = Monday … bit 6 = Sunday.
    public var weekdays: UInt8
    /// yyyymmdd, 0 when the service is defined only by explicit dates.
    public var start: Int
    public var end: Int
    public var added: Set<Int>
    public var removed: Set<Int>

    public func runs(on date: Int, weekday: Int) -> Bool {
        if removed.contains(date) { return false }
        if added.contains(date) { return true }
        guard start > 0, (start...max(start, end)).contains(date) else { return false }
        return weekdays & (1 << UInt8(weekday)) != 0
    }

    /// Latest date this service is defined for.
    var lastDate: Int { max(end, added.max() ?? 0) }
}

public struct StopTime: Hashable, Sendable {
    /// Seconds after midnight of the service day (may exceed 24 h).
    public var arrival: Int32
    public var departure: Int32
    /// Metres along the trip's shape.
    public var distance: Float
    /// Index into `RailNetwork.stations`, or −1.
    public var station: Int32 = -1
}

public struct ScheduledTrip: Sendable {
    public var line: Int
    public var service: Int
    public var shape: Int
    public var tripID: String
    public var headsign: String
    public var trainNumber: String
    public var direction: UInt8
    public var stops: [StopTime]
    public var start: Int32 { stops.first?.departure ?? 0 }
    public var end: Int32 { stops.last?.arrival ?? 0 }
}

/// The bundled network: every line's track, its stations and its timetable. See Tools/build_rail.py.
public final class RailNetwork: Sendable {
    public let lines: [RailLine]
    public let shapes: [RailShape]
    public let stations: [Station]
    public let services: [ServiceCalendar]
    public let trips: [ScheduledTrip]

    private let lineByRoute: [TransitSystem: [String: Int]]
    /// Trips by `tripKey` and by train number: several each where services differ by day.
    private let tripByID: [TransitSystem: [String: [Int]]]
    private let tripByNumber: [TransitSystem: [String: [Int]]]
    private let lineByID: [String: Int]
    private let stationByStop: [TransitSystem: [String: Int]]
    private let stationByKey: [String: Int]
    /// Lines that stop at each station: by system, then trunk lines first (Red, Orange, Blue…; 1 2 3…).
    public let linesAtStation: [[Int]]
    /// Everything the network touches, padded a little.
    public let coverage: GeoBounds
    /// Flat metres for this network's latitude.
    public let metric: LocalMetric
    /// Systems with any line in this network, in order.
    public let systems: [TransitSystem]

    init(lines: [RailLine], shapes: [RailShape], stations: [Station], services: [ServiceCalendar], trips: [ScheduledTrip],
         stopStations: [TransitSystem: [String: Int]] = [:], metric: LocalMetric = .dc) {
        self.lines = lines
        self.shapes = shapes
        var stations = stations
        var seen: [String: Int] = [:]
        for i in stations.indices {
            let base = "\(stations[i].system.rawValue):\(stations[i].name)"
            let n = seen[base, default: 0] + 1
            seen[base] = n
            stations[i].key = n == 1 ? base : "\(base)#\(n)"
        }
        self.stations = stations
        self.services = services
        self.trips = trips
        self.metric = metric
        self.systems = Set(lines.map(\.system)).sorted()
        self.stationByStop = stopStations
        self.stationByKey = Dictionary(stations.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        var served = Array(repeating: Set<Int>(), count: stations.count)
        for t in trips {
            for s in t.stops where s.station >= 0 && Int(s.station) < stations.count { served[Int(s.station)].insert(t.line) }
        }
        // Lines are stored in drawing order, trunk lines last; listed, they come first.
        linesAtStation = served.map { $0.sorted { lines[$0].system != lines[$1].system ? lines[$0].system < lines[$1].system : $0 > $1 } }
        var byRoute: [TransitSystem: [String: Int]] = [:]
        for (i, l) in lines.enumerated() {
            for r in l.routeIDs { byRoute[l.system, default: [:]][r] = i }
        }
        lineByRoute = byRoute
        lineByID = Dictionary(lines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byTrip: [TransitSystem: [String: [Int]]] = [:]
        var byNumber: [TransitSystem: [String: [Int]]] = [:]
        for (i, t) in trips.enumerated() {
            let system = lines[t.line].system
            byTrip[system, default: [:]][Self.tripKey(system: system, tripID: t.tripID), default: []].append(i)
            if !t.trainNumber.isEmpty { byNumber[system, default: [:]][t.trainNumber, default: []].append(i) }
        }
        tripByID = byTrip
        tripByNumber = byNumber
        coverage = GeoBounds(enclosing: shapes.map(\.points)).expanded(by: 0.05)
    }

    public static func load(from url: URL) throws -> RailNetwork {
        try decode(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func line(id: String) -> Int? { lineByID[id] }

    public func station(key: String) -> Int? { stationByKey[key] }

    /// The station a feed's GTFS stop_id belongs to.
    public func station(system: TransitSystem, stopID: String?) -> Int? {
        guard let stopID else { return nil }
        return stationByStop[system]?[stopID]
    }

    /// The GTFS stop_ids of one system at a station (platforms, entrances' parent, and so on).
    public func stopIDs(system: TransitSystem, station: Int) -> [String] {
        (stationByStop[system] ?? [:]).filter { $0.value == station }.map(\.key).sorted()
    }

    /// Systems whose trains stop at a station.
    public func systems(at station: Int) -> Set<TransitSystem> {
        Set((linesAtStation[safe: station] ?? []).map { lines[$0].system })
    }

    /// The line a live feed's route_id belongs to.
    public func line(system: TransitSystem, routeID: String?) -> Int? {
        guard let routeID else { return nil }
        return lineByRoute[system]?[routeID]
    }

    /// The timetabled trip a live vehicle is running: by trip_id, then by train number.
    public func trip(system: TransitSystem, tripID: String?, trainNumber: String?) -> ScheduledTrip? {
        tripIndices(system: system, tripID: tripID, trainNumber: trainNumber).first.map { trips[$0] }
    }

    /// Every timetabled trip a live trip could be (one per service day pattern, when a feed's ids
    /// or train numbers repeat across weekday, Saturday and Sunday timetables).
    public func tripIndices(system: TransitSystem, tripID: String?, trainNumber: String?) -> [Int] {
        if let tripID, let found = tripByID[system]?[Self.tripKey(system: system, tripID: tripID)] { return found }
        if let n = trainNumber, let found = tripByNumber[system]?[n] { return found }
        return []
    }

    /// What live and timetable trip ids have in common. New York City Transit's realtime ids are
    /// the tail of the timetable's ("067300_1..N15R" in "AFA26GEN-1095-Weekday-00_067300_1..N15R"),
    /// and its path codes after the direction can differ: origin time, route and direction identify
    /// a trip ("067300_1_N"). Other feeds use the timetable's ids as they are.
    public static func tripKey(system: TransitSystem, tripID: String) -> String {
        guard system == .nycSubway || system == .statenIsland,
              let m = tripID.firstMatch(of: /(\d{6})_([A-Za-z0-9]+)\.+([NS])/) else { return tripID }
        return "\(m.1)_\(m.2)_\(m.3)"
    }

    public static func decode(_ file: Data) throws -> RailNetwork {
        try BinaryFile.inflate(file, magic: "TSRL", version: 3) { r in
            let metric = LocalMetric(latitude: Double(try r.i32()) / 100_000)
            let stringCount = try r.int()
            var strings: [String] = []
            strings.reserveCapacity(stringCount)
            for _ in 0..<stringCount { strings.append(try r.string()) }
            func str(_ r: inout BinaryReader) throws -> String {
                let i = try r.int()
                guard i < strings.count else { throw GeoDataError.invalid }
                return strings[i]
            }
            func system(_ r: inout BinaryReader) throws -> TransitSystem {
                guard let s = TransitSystem(rawValue: Int(try r.u8())) else { throw GeoDataError.invalid }
                return s
            }

            var lines: [RailLine] = []
            for _ in 0..<(try r.int()) {
                let sys = try system(&r)
                let id = try str(&r), name = try str(&r), short = try str(&r)
                let color = try r.u24(), text = try r.u24(), map = try r.u24()
                var routes: [String] = []
                for _ in 0..<(try r.int()) { routes.append(try str(&r)) }
                lines.append(RailLine(id: id, system: sys, name: name, shortName: short, color: color, textColor: text,
                                      mapColor: map, routeIDs: routes))
            }

            var shapes: [RailShape] = []
            for _ in 0..<(try r.int()) {
                let line = try r.int()
                guard line < lines.count else { throw GeoDataError.invalid }
                shapes.append(RailShape(line: line, points: try r.polyline(count: try r.int()), metric: metric))
            }

            var stations: [Station] = []
            for _ in 0..<(try r.int()) {
                let sys = try system(&r)
                let name = try str(&r)
                let lat = Double(try r.i32()) / 100_000, lon = Double(try r.i32()) / 100_000
                let rank = try r.u8()
                stations.append(Station(system: sys, name: name, position: Coordinate(latitude: lat, longitude: lon), rank: rank,
                                        code: try str(&r)))
            }

            var stopStations: [TransitSystem: [String: Int]] = [:]
            for _ in 0..<(try r.int()) {
                let sys = try system(&r)
                let stopID = try str(&r)
                let station = try r.int()
                guard station < stations.count else { throw GeoDataError.invalid }
                stopStations[sys, default: [:]][stopID] = station
            }

            var services: [ServiceCalendar] = []
            for _ in 0..<(try r.int()) {
                let sys = try system(&r)
                let mask = try r.u8()
                let start = Int(try r.u32()), end = Int(try r.u32())
                var added = Set<Int>(), removed = Set<Int>()
                for _ in 0..<(try r.int()) { added.insert(Int(try r.u32())) }
                for _ in 0..<(try r.int()) { removed.insert(Int(try r.u32())) }
                services.append(ServiceCalendar(system: sys, weekdays: mask, start: start, end: end, added: added, removed: removed))
            }

            var trips: [ScheduledTrip] = []
            let tripCount = try r.int()
            trips.reserveCapacity(tripCount)
            for _ in 0..<tripCount {
                let line = try r.int(), service = try r.int(), shape = try r.int()
                guard line < lines.count, service < services.count, shape < shapes.count else { throw GeoDataError.invalid }
                let tripID = try str(&r), headsign = try str(&r), number = try str(&r)
                let direction = try r.u8()
                let n = try r.int()
                var stops: [StopTime] = []
                stops.reserveCapacity(n)
                var t = 0, d = 0
                for _ in 0..<n {
                    let arrival = t + (try r.int())
                    let departure = arrival + (try r.int())
                    d += try r.int()
                    let station = try r.int() - 1
                    guard station < stations.count else { throw GeoDataError.invalid }
                    stops.append(StopTime(arrival: Int32(arrival), departure: Int32(departure), distance: Float(d),
                                          station: Int32(station)))
                    t = departure
                }
                trips.append(ScheduledTrip(line: line, service: service, shape: shape, tripID: tripID, headsign: headsign,
                                           trainNumber: number, direction: direction, stops: stops))
            }
            return RailNetwork(lines: lines, shapes: shapes, stations: stations, services: services, trips: trips,
                               stopStations: stopStations, metric: metric)
        }
    }
}

/// Flat metres around a network's latitude. Within ±150 km of it the error is well under 1%.
public struct LocalMetric: Sendable, Hashable {
    public let latitude: Double
    let metersPerDegLat = 110_540.0
    let metersPerDegLon: Double

    public init(latitude: Double) {
        self.latitude = latitude
        metersPerDegLon = 111_320.0 * cos(latitude * .pi / 180)
    }

    /// DC–Baltimore's, for networks built in code (tests).
    public static let dc = LocalMetric(latitude: 38.9)

    func xy(_ p: GeoPoint) -> SIMD2<Double> {
        SIMD2(Double(p.y) * metersPerDegLon, Double(p.x) * metersPerDegLat)
    }

    func xy(_ c: Coordinate) -> SIMD2<Double> {
        SIMD2(c.longitude * metersPerDegLon, c.latitude * metersPerDegLat)
    }

    func coordinate(_ v: SIMD2<Double>) -> Coordinate {
        Coordinate(latitude: v.y / metersPerDegLat, longitude: v.x / metersPerDegLon)
    }

    func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let d = xy(b) - xy(a)
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// Bearing from a to b in degrees clockwise from north.
    func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let d = xy(b) - xy(a)
        let deg = atan2(d.x, d.y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}

extension Coordinate {
    public init(_ p: GeoPoint) { self.init(latitude: Double(p.x), longitude: Double(p.y)) }
}
