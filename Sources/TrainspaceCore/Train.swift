import Foundation

public enum TrainStatus: String, Sendable, Hashable {
    case stopped, arriving, moving
}

/// One position report for one train, from a live feed or estimated from the timetable.
public struct TrainReport: Hashable, Sendable {
    /// Stable identity across reports: system prefix + vehicle or trip id.
    public var id: String
    public var system: TransitSystem
    /// Index into `RailNetwork.lines`, when known.
    public var line: Int?
    public var trainNumber: String?
    /// Where it's going.
    public var headsign: String?
    public var position: Coordinate
    /// Degrees clockwise from north.
    public var bearingDeg: Double?
    public var speedMph: Double?
    public var status: TrainStatus?
    /// GTFS direction_id (0 or 1), when known.
    public var direction: Int?
    /// Estimated from the timetable rather than reported by the train.
    public var isScheduled: Bool
    /// Local epoch seconds when this position was observed.
    public var fixTime: TimeInterval

    public init(id: String, system: TransitSystem, line: Int? = nil, trainNumber: String? = nil, headsign: String? = nil,
                position: Coordinate, bearingDeg: Double? = nil, speedMph: Double? = nil, status: TrainStatus? = nil,
                isScheduled: Bool = false, direction: Int? = nil, fixTime: TimeInterval) {
        self.id = id
        self.system = system
        self.line = line
        self.trainNumber = trainNumber
        self.headsign = headsign
        self.position = position
        self.bearingDeg = bearingDeg
        self.speedMph = speedMph
        self.status = status
        self.isScheduled = isScheduled
        self.direction = direction
        self.fixTime = fixTime
    }

    /// "RD", "MARC 677", "AMTK 164", "LR", "A".
    public func label(network: RailNetwork?) -> String {
        if let prefix = system.labelPrefix {
            if let n = trainNumber, !n.isEmpty { return "\(prefix) \(n)" }
            return prefix
        }
        if let line, let l = network?.lines[safe: line] { return l.shortName }
        return system.labelPrefix ?? (trainNumber ?? system.name)
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Station names in headsigns arrive in every style ("SHADY GROVE", "Union Station", "BOS").
public enum Headsign {
    public static func clean(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let fixed = fixes[s.uppercased()] { return fixed }
        for suffix in [" STATION (METRO)", " (METRO)", " STATION", " MARC"] where s.uppercased().hasSuffix(suffix)
            && !keepStation.contains(String(s.uppercased().dropLast(suffix.count))) {
            s = String(s.dropLast(suffix.count))
        }
        return s.isEmpty ? nil : s
    }

    /// "South Station", not "South".
    static let keepStation: Set<String> = ["SOUTH", "NORTH", "PENN", "UNION", "SUBURBAN", "JEFFERSON", "30TH STREET", "30TH ST"]

    /// Headsigns the feeds truncate or phrase oddly.
    static let fixes: [String: String] = [
        "BALTIMORE AND MARTIN AIR": "MARTIN AIRPORT",
        "BALTIMORE AND MARTIN AIRPORT": "MARTIN AIRPORT",
        "BALTIMORE CAMDEN": "CAMDEN YARDS",
        "WASHINGTON UNION STATION": "UNION STATION",
        "30TH ST. PHL.": "30TH STREET",
        "NEW YORK PENN STATION": "PENN STATION",
        "GRAND CENTRAL TERMINAL": "GRAND CENTRAL",
    ]
}
