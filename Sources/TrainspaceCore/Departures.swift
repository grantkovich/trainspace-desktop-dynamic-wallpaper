import Foundation

/// One train leaving a station.
public struct Departure: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Timetable only: nothing live is known about this train.
        case scheduled
        case onTime
        case late(minutes: Int)
        case early(minutes: Int)
        case cancelled
    }

    /// Stable across refreshes: system, service day and trip.
    public var id: String
    public var system: TransitSystem
    public var line: Int
    public var trainNumber: String
    public var destination: String
    public var scheduled: Date
    /// Best estimate of when it leaves: live where known, otherwise the timetable.
    public var expected: Date
    public var status: Status
    /// The operator's own remark, when it gives one (Amtrak: "05 MI LATE").
    public var remark: String?

    public var isLive: Bool { status != .scheduled }
}

/// What the live feeds currently say about trips, for adjusting departures.
public struct LiveDepartureData: Sendable {
    /// GTFS-Realtime trip updates per system.
    public var tripUpdates: [TransitSystem: [TripUpdate]]
    /// Amtrak's times at its stations.
    public var amtrak: [AmtrakFeed.StationTime]

    public init(tripUpdates: [TransitSystem: [TripUpdate]] = [:], amtrak: [AmtrakFeed.StationTime] = []) {
        self.tripUpdates = tripUpdates
        self.amtrak = amtrak
    }
}

/// Departure boards for any station, from the bundled timetables plus live corrections.
public final class DepartureBoard: Sendable {
    private struct Visit: Sendable {
        var trip: Int32
        var stop: Int16
    }

    public let network: RailNetwork
    private let estimator: ScheduleEstimator
    /// Per station: every timetabled call that isn't the trip's last stop.
    private let visits: [[Visit]]

    public init(network: RailNetwork, estimator: ScheduleEstimator? = nil) {
        self.network = network
        self.estimator = estimator ?? ScheduleEstimator(network: network)
        var v = Array(repeating: [Visit](), count: network.stations.count)
        for (ti, trip) in network.trips.enumerated() {
            for (si, stop) in trip.stops.enumerated().dropLast() where stop.station >= 0 {
                v[Int(stop.station)].append(Visit(trip: Int32(ti), stop: Int16(si)))
            }
        }
        visits = v.map { calls in calls.sorted { network.trips[Int($0.trip)].stops[Int($0.stop)].departure < network.trips[Int($1.trip)].stops[Int($1.stop)].departure } }
    }

    /// The next departures from `station` after `date`, earliest first.
    /// - Parameters:
    ///   - systems: only these systems' trains (a hub board shows mainline; a metro sign shows metro).
    ///   - horizon: how far ahead to look.
    ///   - byExpected: soonest first by live estimate (countdown signs) rather than by timetable (departure boards).
    public func departures(at station: Int, systems: Set<TransitSystem>, after date: Date, limit: Int,
                           horizon: TimeInterval = 4 * 3600, live: LiveDepartureData = .init(),
                           byExpected: Bool = false) -> [Departure] {
        guard let calls = visits[safe: station], !calls.isEmpty else { return [] }
        let calendar = estimator.calendar
        let today = calendar.startOfDay(for: date)
        var out: [Departure] = []
        let index = LiveIndex(live, network: network)

        for offset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            var active: [TransitSystem: Set<Int>] = [:]
            for s in systems { active[s] = estimator.activeServices(system: s, on: day) }
            let dayKey = ScheduleEstimator.yyyymmdd(day, calendar)
            for call in calls {
                let trip = network.trips[Int(call.trip)]
                let line = network.lines[trip.line]
                guard systems.contains(line.system), active[line.system]?.contains(trip.service) == true else { continue }
                let stop = trip.stops[Int(call.stop)]
                // Service days start at local midnight; GTFS times count from there and may pass 24:00.
                guard let scheduled = calendar.date(byAdding: .second, value: Int(stop.departure), to: day) else { continue }
                guard scheduled >= date.addingTimeInterval(-30 * 60), scheduled <= date.addingTimeInterval(horizon) else { continue }
                var d = Departure(id: "\(line.system.rawValue):\(dayKey):\(trip.tripID)", system: line.system, line: trip.line,
                                  trainNumber: trip.trainNumber, destination: destination(of: trip),
                                  scheduled: scheduled, expected: scheduled, status: .scheduled)
                index.apply(to: &d, trip: trip, stopIndex: Int(call.stop), station: station, day: day, calendar: calendar)
                // Gone: left (or should have left) more than half a minute ago.
                guard d.expected >= date.addingTimeInterval(-30) || d.status == .cancelled && scheduled >= date.addingTimeInterval(-60) else { continue }
                out.append(d)
            }
        }
        if byExpected {
            out.sort { $0.expected != $1.expected ? $0.expected < $1.expected : $0.id < $1.id }
        } else {
            out.sort { $0.scheduled != $1.scheduled ? $0.scheduled < $1.scheduled : $0.id < $1.id }
        }
        return Array(out.prefix(limit))
    }

    private func destination(of trip: ScheduledTrip) -> String {
        if let h = Headsign.clean(trip.headsign) { return h }
        if let last = trip.stops.last, last.station >= 0, let s = network.stations[safe: Int(last.station)] { return s.name }
        return network.lines[trip.line].name
    }
}

/// Live data, indexed for lookups by trip.
private struct LiveIndex {
    var byTrip: [TransitSystem: [String: TripUpdate]] = [:]
    var byNumber: [TransitSystem: [String: TripUpdate]] = [:]
    var amtrak: [String: [AmtrakFeed.StationTime]] = [:]
    let network: RailNetwork

    init(_ live: LiveDepartureData, network: RailNetwork) {
        self.network = network
        for (system, updates) in live.tripUpdates {
            for u in updates {
                if let id = u.tripID {
                    byTrip[system, default: [:]][RailNetwork.tripKey(system: system, tripID: id)] = u
                    if let n = GTFSRealtimeSource.trainNumber(fromTripID: id, system: system) { byNumber[system, default: [:]][n] = u }
                }
            }
        }
        for t in live.amtrak { amtrak[t.trainNumber, default: []].append(t) }
    }

    func apply(to d: inout Departure, trip: ScheduledTrip, stopIndex: Int, station: Int, day: Date, calendar: Calendar) {
        if d.system == .amtrak {
            applyAmtrak(to: &d, station: station)
            return
        }
        guard let u = byTrip[d.system]?[RailNetwork.tripKey(system: d.system, tripID: trip.tripID)] ?? (trip.trainNumber.isEmpty ? nil : byNumber[d.system]?[trip.trainNumber]) else { return }
        if let date = u.startDate, let wanted = Int(date), wanted != ScheduleEstimator.yyyymmdd(day, calendar) { return }
        if u.canceled {
            d.status = .cancelled
            return
        }
        // The update at this station, or the last one before it: delays carry forward down the line.
        var delay: Double?
        var bestStop = -1
        for s in u.stops {
            guard let st = network.station(system: d.system, stopID: s.stopID),
                  let idx = trip.stops.firstIndex(where: { $0.station == Int32(st) }), idx <= stopIndex, idx > bestStop else { continue }
            if idx == stopIndex, s.skipped {
                d.status = .cancelled
                return
            }
            let scheduledThere = calendar.date(byAdding: .second, value: Int(trip.stops[idx].departure), to: day) ?? d.scheduled
            if let t = s.departureTime ?? s.arrivalTime {
                delay = t - scheduledThere.timeIntervalSince1970
            } else if let dl = s.departureDelay ?? s.arrivalDelay {
                delay = Double(dl)
            } else { continue }
            bestStop = idx
        }
        if delay == nil, let dl = u.delay { delay = Double(dl) }
        guard let delay else { return }
        d.expected = d.scheduled.addingTimeInterval(delay)
        d.status = Self.status(delay)
    }

    private func applyAmtrak(to d: inout Departure, station: Int) {
        guard let code = network.stations[safe: station]?.code, !code.isEmpty,
              let times = amtrak[d.trainNumber],
              // The same train number runs every day: pick the call closest to this departure.
              let t = times.filter({ $0.code == code })
                .min(by: { abs(($0.scheduledDeparture ?? .distantPast).timeIntervalSince(d.scheduled))
                    < abs(($1.scheduledDeparture ?? .distantPast).timeIntervalSince(d.scheduled)) }),
              let sched = t.scheduledDeparture, abs(sched.timeIntervalSince(d.scheduled)) < 12 * 3600 else { return }
        d.scheduled = sched
        d.remark = t.comment
        if let gone = t.departed {
            d.expected = gone
            d.status = Self.status(gone.timeIntervalSince(sched))
        } else if let est = t.estimatedDeparture {
            d.expected = est
            d.status = Self.status(est.timeIntervalSince(sched))
        }
    }

    static func status(_ delay: Double) -> Departure.Status {
        let minutes = Int((delay / 60).rounded())
        if minutes > 1 { return .late(minutes: minutes) }
        if minutes < -1 { return .early(minutes: -minutes) }
        return .onTime
    }
}
