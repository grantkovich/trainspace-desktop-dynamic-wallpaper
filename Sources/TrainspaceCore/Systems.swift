import Foundation

/// What a system is, for drawing and grouping: metro cars are drawn shorter than commuter and
/// intercity trains; metro lines sharing track share an LED pair; mainline systems get one pair.
public enum SystemKind: String, Sendable, Hashable {
    case rapidTransit, lightRail, commuter, intercity

    public var isMainline: Bool { self == .commuter || self == .intercity }
}

public struct SystemInfo: Sendable, Hashable {
    public var name: String
    /// Who runs it, for Settings.
    public var operatorName: String
    public var kind: SystemKind
    /// Prefix on map labels for systems whose trains are known by number ("LIRR 1234").
    public var labelPrefix: String?
    /// Colour when colouring by system: a map colour, tuned per palette by `Palette.lineColor`.
    public var color: UInt32
}

/// A rail system. Raw values are stable: they're stored in the bundled network files and in
/// settings. Systems behave like an enum (`.metrorail`, `.nycSubway`) but their details live in
/// one table, so adding a region is mostly data.
public struct TransitSystem: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard Self.table[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(_ raw: Int) { rawValue = raw }

    // DC–Baltimore
    public static let metrorail = TransitSystem(0)
    public static let marc = TransitSystem(1)
    public static let vre = TransitSystem(2)
    public static let amtrak = TransitSystem(3)
    public static let lightRail = TransitSystem(4)
    public static let subway = TransitSystem(5)
    // New York
    public static let nycSubway = TransitSystem(6)
    public static let statenIsland = TransitSystem(7)
    public static let lirr = TransitSystem(8)
    public static let metroNorth = TransitSystem(9)
    public static let njtRail = TransitSystem(10)
    public static let njtLightRail = TransitSystem(11)
    public static let path = TransitSystem(12)
    // Philadelphia
    public static let septaRail = TransitSystem(13)
    public static let septaMetro = TransitSystem(14)
    public static let patco = TransitSystem(15)
    // Boston
    public static let mbtaSubway = TransitSystem(16)
    public static let mbtaCommuter = TransitSystem(17)

    static let table: [Int: SystemInfo] = [
        0: .init(name: "Metrorail", operatorName: "WMATA · Washington", kind: .rapidTransit, labelPrefix: nil, color: 0x009CDE),
        1: .init(name: "MARC", operatorName: "MDOT MTA · Maryland commuter rail", kind: .commuter, labelPrefix: "MARC", color: 0x8A3FC4),
        2: .init(name: "VRE", operatorName: "Virginia Railway Express", kind: .commuter, labelPrefix: "VRE", color: 0xD0337F),
        3: .init(name: "Amtrak", operatorName: "Amtrak · Northeast Corridor and beyond", kind: .intercity, labelPrefix: "AMTK", color: 0x2A2B2E),
        4: .init(name: "Light RailLink", operatorName: "MDOT MTA · Baltimore", kind: .lightRail, labelPrefix: nil, color: 0x007499),
        5: .init(name: "Metro SubwayLink", operatorName: "MDOT MTA · Baltimore", kind: .rapidTransit, labelPrefix: nil, color: 0x008000),
        6: .init(name: "Subway", operatorName: "MTA New York City Transit", kind: .rapidTransit, labelPrefix: nil, color: 0x0062CF),
        7: .init(name: "Staten Island Railway", operatorName: "MTA New York City Transit", kind: .rapidTransit, labelPrefix: nil, color: 0x2F6DB5),
        8: .init(name: "LIRR", operatorName: "MTA Long Island Rail Road", kind: .commuter, labelPrefix: "LIRR", color: 0xA626AA),
        9: .init(name: "Metro-North", operatorName: "MTA Metro-North Railroad", kind: .commuter, labelPrefix: "MNR", color: 0xEE0034),
        10: .init(name: "NJ Transit Rail", operatorName: "NJ TRANSIT", kind: .commuter, labelPrefix: "NJT", color: 0xF37021),
        11: .init(name: "NJ Transit Light Rail", operatorName: "NJ TRANSIT", kind: .lightRail, labelPrefix: nil, color: 0x008080),
        12: .init(name: "PATH", operatorName: "Port Authority of NY & NJ", kind: .rapidTransit, labelPrefix: nil, color: 0x65C100),
        13: .init(name: "SEPTA Regional Rail", operatorName: "SEPTA · Philadelphia", kind: .commuter, labelPrefix: "SEPTA", color: 0x4F758B),
        14: .init(name: "SEPTA Metro", operatorName: "SEPTA · Philadelphia", kind: .rapidTransit, labelPrefix: nil, color: 0x0097D6),
        15: .init(name: "PATCO", operatorName: "Delaware River Port Authority", kind: .rapidTransit, labelPrefix: nil, color: 0xBC0035),
        16: .init(name: "MBTA Subway", operatorName: "MBTA · Boston", kind: .rapidTransit, labelPrefix: nil, color: 0xDA291C),
        17: .init(name: "MBTA Commuter Rail", operatorName: "MBTA · Boston", kind: .commuter, labelPrefix: "MBTA", color: 0x80276C),
    ]

    public static let allCases: [TransitSystem] = table.keys.sorted().map(TransitSystem.init)

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var info: SystemInfo { Self.table[rawValue]! }
    public var name: String { info.name }
    public var operatorName: String { info.operatorName }
    public var kind: SystemKind { info.kind }
    public var labelPrefix: String? { info.labelPrefix }
    /// Commuter and intercity trains are drawn longer than metro and light rail cars.
    public var isMainline: Bool { info.kind.isMainline }

    // Stored as the raw number, so settings from earlier versions still decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard Self.table[raw] != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown system \(raw)"))
        }
        rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A metro area with its own bundled network, base map and places.
public struct Region: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var systems: [TransitSystem]
    public var presets: [PlacePreset]
    /// Amtrak station codes and station names whose great halls get the split-flap board.
    public var hubCodes: Set<String>
    public var hubNames: Set<String>
    /// Station shown in station view until one is chosen (its `Station.key`).
    public var defaultStation: String
    /// Roughly where the network runs, for recognising which region a place is in.
    public var bounds: GeoBounds
    /// Station names offered on the welcome window.
    public var featured: [String] = []
    /// What the location field suggests typing.
    public var searchHint: String = ""

    /// Bundled files: `rail-<id>.bin`, `geodata-<id>.bin`.
    public var railFile: String { "rail-\(id)" }
    public var geoFile: String { "geodata-\(id)" }

    public static let dcBaltimore = Region(
        id: "dcbal", name: "DC–Baltimore",
        systems: [.metrorail, .marc, .vre, .amtrak, .lightRail, .subway],
        presets: [
            PlacePreset(name: "Washington", center: Coordinate(latitude: 38.8990, longitude: -77.0230), zoomMiles: 6),
            PlacePreset(name: "Baltimore", center: Coordinate(latitude: 39.3000, longitude: -76.6200), zoomMiles: 6),
            PlacePreset(name: "DC–Baltimore", center: Coordinate(latitude: 39.0950, longitude: -76.8300), zoomMiles: 24),
            PlacePreset(name: "Whole Network", center: Coordinate(latitude: 38.9300, longitude: -77.0000), zoomMiles: 42),
        ],
        hubCodes: ["WAS", "BAL"], hubNames: [], defaultStation: "0:Union Station",
        bounds: GeoBounds(minLat: 37.85, maxLat: 40.15, minLon: -78.75, maxLon: -75.9),
        featured: ["Union Station", "Penn Station", "Metro Center"], searchHint: "20001  ·  Silver Spring  ·  38.90, -77.04")

    public static let newYork = Region(
        id: "nyc", name: "New York",
        systems: [.nycSubway, .statenIsland, .lirr, .metroNorth, .njtRail, .njtLightRail, .path, .amtrak],
        presets: [
            PlacePreset(name: "Manhattan", center: Coordinate(latitude: 40.7590, longitude: -73.9700), zoomMiles: 6),
            PlacePreset(name: "Midtown", center: Coordinate(latitude: 40.7540, longitude: -73.9840), zoomMiles: 2.5),
            PlacePreset(name: "New York City", center: Coordinate(latitude: 40.7200, longitude: -73.9400), zoomMiles: 14),
            PlacePreset(name: "Whole Network", center: Coordinate(latitude: 40.8600, longitude: -73.6000), zoomMiles: 60),
        ],
        hubCodes: ["NYP"], hubNames: ["Grand Central", "Grand Central-42 St"], defaultStation: "6:Grand Central-42 St",
        bounds: GeoBounds(minLat: 39.95, maxLat: 41.9, minLon: -75.1, maxLon: -71.85),
        featured: ["Grand Central-42 St", "Penn Station", "Times Sq-42 St"], searchHint: "10001  ·  Astoria  ·  40.75, -73.99")

    public static let philadelphia = Region(
        id: "phl", name: "Philadelphia",
        systems: [.septaRail, .septaMetro, .patco, .njtRail, .njtLightRail, .amtrak],
        presets: [
            PlacePreset(name: "Philadelphia", center: Coordinate(latitude: 39.9700, longitude: -75.1500), zoomMiles: 8),
            PlacePreset(name: "Center City", center: Coordinate(latitude: 39.9526, longitude: -75.1652), zoomMiles: 2.5),
            PlacePreset(name: "Whole Network", center: Coordinate(latitude: 39.9600, longitude: -75.2000), zoomMiles: 34),
        ],
        hubCodes: ["PHL"], hubNames: [], defaultStation: "14:30th Street Station",
        bounds: GeoBounds(minLat: 39.3, maxLat: 40.45, minLon: -75.9, maxLon: -74.35),
        featured: ["30th Street Station", "15th St/City Hall", "Jefferson Station"], searchHint: "19103  ·  Germantown  ·  39.95, -75.17")

    public static let boston = Region(
        id: "bos", name: "Boston",
        systems: [.mbtaSubway, .mbtaCommuter, .amtrak],
        presets: [
            PlacePreset(name: "Boston", center: Coordinate(latitude: 42.3500, longitude: -71.0800), zoomMiles: 7),
            PlacePreset(name: "Downtown", center: Coordinate(latitude: 42.3570, longitude: -71.0600), zoomMiles: 2.5),
            PlacePreset(name: "Whole Network", center: Coordinate(latitude: 42.3500, longitude: -71.2500), zoomMiles: 40),
        ],
        hubCodes: ["BOS"], hubNames: [], defaultStation: "16:South Station",
        bounds: GeoBounds(minLat: 41.5, maxLat: 42.95, minLon: -71.95, maxLon: -70.55),
        featured: ["South Station", "Park Street", "North Station"], searchHint: "02110  ·  Cambridge  ·  42.35, -71.06")

    public static let all: [Region] = [.dcBaltimore, .newYork, .philadelphia, .boston]

    public static func with(id: String) -> Region { all.first { $0.id == id } ?? .dcBaltimore }

    /// The region a place is in, if any; where regions overlap (Trenton), the one whose centre is nearer.
    public static func containing(_ c: Coordinate) -> Region? {
        all.filter { $0.bounds.contains(c) }.min { a, b in
            Geo.distanceNM(a.presets[0].center, c) < Geo.distanceNM(b.presets[0].center, c)
        }
    }
}
