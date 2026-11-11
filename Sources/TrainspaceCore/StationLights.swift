import Foundation

/// Stations drawn as little pills of LEDs, like a light-up transit map: each station gets an
/// LED pair (one per direction) for each group of lines it serves, and a train lights the LED
/// at its station in its line's colour.
public struct StationLights: Sendable {
    public struct Node: Sendable {
        public var station: Int
        /// One LED pair per platform group. Metrorail lines that share track here share a pair
        /// (Metro Center: Red, then Orange/Blue/Silver); other systems get one pair each.
        public var groups: [[Int]]
        /// Bearing of the track through the station (0…180°), for orienting the pill and telling
        /// which way a train is heading.
        public var trackBearing: Double
    }

    public struct LED: Hashable, Sendable {
        public var station: Int
        public var group: Int
        /// 0 or 1: which of the pair (one per direction of travel).
        public var side: Int
    }

    /// Where a train is relative to the station it lights.
    public enum Phase: Sendable, Equatable {
        /// Stopped at, or right by, the station: steady light.
        case atStation
        /// On its way in or out: blinking.
        case inTransit
    }

    public private(set) var nodes: [Int: Node] = [:]
    private var stationsByLine: [Int: [Int]] = [:]
    let network: RailNetwork

    public init(network: RailNetwork) {
        self.network = network
        var neighbours: [Int: [Int: Set<Int>]] = [:]   // station → line → neighbouring stations
        for trip in network.trips {
            let stations = trip.stops.map { Int($0.station) }.filter { $0 >= 0 }
            for (a, b) in zip(stations, stations.dropFirst()) where a != b {
                neighbours[a, default: [:]][trip.line, default: []].insert(b)
                neighbours[b, default: [:]][trip.line, default: []].insert(a)
            }
        }
        for (s, byLine) in neighbours {
            let lines = byLine.keys.sorted {
                let a = network.lines[$0], b = network.lines[$1]
                return a.system != b.system ? a.system < b.system : $0 > $1
            }
            var groups: [[Int]] = []
            for l in lines {
                let line = network.lines[l]
                let mine = byLine[l]!
                let match = groups.firstIndex { group in
                    guard let first = group.first, network.lines[first].system == line.system else { return false }
                    // Commuter and intercity rail: one pair per system. Metro and light rail: lines sharing track.
                    return line.system.kind.isMainline || group.contains { !byLine[$0]!.isDisjoint(with: mine) }
                }
                if let match { groups[match].append(l) } else { groups.append([l]) }
            }
            // Track direction: average of the bearings to neighbours, ignoring which way they point.
            var x = 0.0, y = 0.0
            for n in byLine.values.reduce(Set<Int>(), { $0.union($1) }) {
                let b = Geo.bearing(network.stations[s].position, network.stations[n].position) * .pi / 180
                x += cos(2 * b); y += sin(2 * b)
            }
            var bearing = atan2(y, x) / 2 * 180 / .pi
            if bearing < 0 { bearing += 180 }
            nodes[s] = Node(station: s, groups: groups, trackBearing: bearing)
            for l in lines { stationsByLine[l, default: []].append(s) }
        }
    }

    /// The LED a train lights: the nearest station on its line, the pair its line uses there,
    /// and the side for the way it's heading. Trains further than `maxMeters` from any of their
    /// line's stations light nothing.
    public func led(for train: TrainReport, position: Coordinate, heading: Double?,
                    maxMeters: Double = 8_000) -> (LED, Phase)? {
        guard let line = train.line, let candidates = stationsByLine[line] else { return nil }
        let p = network.metric.xy(position)
        var best: (station: Int, meters: Double)?
        for s in candidates {
            let d = network.metric.xy(network.stations[s].position) - p
            let m = (d.x * d.x + d.y * d.y).squareRoot()
            if m <= maxMeters, best == nil || m < best!.meters { best = (s, m) }
        }
        guard let best, let node = nodes[best.station] else { return nil }
        let group = node.groups.firstIndex { $0.contains(line) } ?? 0
        let side: Int
        if let heading {
            side = cos((heading - node.trackBearing) * .pi / 180) >= 0 ? 0 : 1
        } else {
            side = (train.direction ?? 0) % 2
        }
        let atStation = train.status == .stopped || best.meters < 250
        return (LED(station: best.station, group: group, side: side), atStation ? .atStation : .inTransit)
    }
}
